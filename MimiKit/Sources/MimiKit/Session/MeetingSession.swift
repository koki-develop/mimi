import Darwin
import Foundation
import Observation

/// Captures both sides of a meeting, transcribes them, and periodically summarizes the current topic.
@MainActor
@Observable
public final class MeetingSession {
    public enum State: Sendable {
        case idle
        case starting
        case running
        case stopping
    }

    public enum Failure: Error {
        case microphoneAccessDenied
        case audioCapture(any Error)
        case transcription(any Error)
    }

    public enum SummaryFailure: Error {
        case modelLoading(any Error)
        case summarization(any Error)
    }

    public enum SummaryActivity: Sendable, Equatable {
        case idle
        case loadingModel(progress: Double)
        case summarizing
    }

    public private(set) var state = State.idle
    public private(set) var transcript = Transcript()
    public private(set) var currentTopic = ""
    public private(set) var summaryActivity = SummaryActivity.idle
    public private(set) var lastSummaryDuration: Duration?
    /// The reason the last session failed to start or stopped unexpectedly.
    public private(set) var failure: Failure?
    public private(set) var summaryFailure: SummaryFailure?

    public let microphoneLevel = AudioLevelMeter()
    public let systemAudioLevel = AudioLevelMeter()

    @ObservationIgnored private let microphone: any AudioSource
    @ObservationIgnored private let systemAudio: any AudioSource
    @ObservationIgnored private let makeTranscriptionEngine: () -> any TranscriptionEngine
    @ObservationIgnored private let textGeneratorProvider: any TextGeneratorProvider
    @ObservationIgnored private let summaryInterval: Duration

    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var engines: [any TranscriptionEngine] = []
    @ObservationIgnored private var resultTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var summaryTask: Task<Void, Never>?

    public init(
        microphone: any AudioSource,
        systemAudio: any AudioSource,
        makeTranscriptionEngine: @escaping () -> any TranscriptionEngine,
        textGeneratorProvider: any TextGeneratorProvider,
        summaryInterval: Duration
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.makeTranscriptionEngine = makeTranscriptionEngine
        self.textGeneratorProvider = textGeneratorProvider
        self.summaryInterval = summaryInterval
    }

    /// Starts a session. Does nothing unless the session is idle.
    public func start(summaryModelID: String) async {
        guard state == .idle else { return }
        state = .starting
        transcript = Transcript()
        currentTopic = ""
        lastSummaryDuration = nil
        failure = nil
        summaryFailure = nil

        let task = Task { [self] in await performStart(summaryModelID: summaryModelID) }
        startTask = task
        await task.value
        startTask = nil
    }

    /// Stops the session once every pending transcription result has been applied.
    /// If the session is starting, waits for it to finish starting first.
    /// Returns once the session is idle.
    public func stop() async {
        await startTask?.value
        await stopRunning()
    }

    private func stopRunning() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard state == .running else { return }
        state = .stopping
        let task = Task { [self] in
            await tearDown()
            state = .idle
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStart(summaryModelID: String) async {
        guard await microphone.requestAccess() else {
            record(.microphoneAccessDenied)
            state = .idle
            return
        }

        do {
            try await startCapture()
        } catch {
            record(error)
        }
        // Also covers a source or engine that failed asynchronously while the other one was still starting.
        guard failure == nil else {
            await tearDown()
            state = .idle
            return
        }

        state = .running
        summaryTask = Task { [self] in await runSummaryLoop(modelID: summaryModelID) }
    }

    private func startCapture() async throws(Failure) {
        let timelineOrigin = mach_absolute_time()
        let sources: [(source: any AudioSource, speaker: Speaker, meter: AudioLevelMeter)] = [
            (microphone, .me, microphoneLevel),
            (systemAudio, .others, systemAudioLevel),
        ]
        for (source, speaker, meter) in sources {
            let engine = makeTranscriptionEngine()
            engines.append(engine)
            do {
                observe(try await engine.start(timelineOrigin: timelineOrigin), from: speaker)
            } catch {
                throw .transcription(error)
            }
            do {
                try source.start(
                    onBuffer: { @Sendable buffer, hostTime in
                        engine.append(buffer, hostTime: hostTime)
                        meter.update(with: buffer)
                    },
                    onFailure: { [weak self] error in self?.fail(.audioCapture(error)) }
                )
            } catch {
                throw .audioCapture(error)
            }
        }
    }

    private func observe(_ results: AsyncThrowingStream<TranscriptionResult, any Error>, from speaker: Speaker) {
        resultTasks.append(Task { [self] in
            do {
                for try await result in results {
                    transcript.apply(result, from: speaker)
                }
            } catch {
                fail(.transcription(error))
            }
        })
    }

    /// Records a failure that occurred while the session was starting or running, and stops the session.
    /// While starting, ``performStart(summaryModelID:)`` checks for failures before the session runs.
    private func fail(_ failure: Failure) {
        record(failure)
        if state == .running {
            // Runs separately because stopping awaits the result tasks this may be called from.
            Task { await stopRunning() }
        }
    }

    /// Keeps the first failure, which is the root cause of any failures that follow it.
    private func record(_ failure: Failure) {
        self.failure = self.failure ?? failure
    }

    private func tearDown() async {
        // Capture ends first so that it stops immediately, even while the summary task is still finishing.
        microphone.stop()
        systemAudio.stop()
        await withTaskGroup { group in
            for engine in engines {
                group.addTask { await engine.finish() }
            }
        }
        engines = []
        for task in resultTasks {
            await task.value
        }
        resultTasks = []
        microphoneLevel.reset()
        systemAudioLevel.reset()

        // Loading model weights is not cancellable, so this can wait for an in-flight load to finish.
        summaryTask?.cancel()
        await summaryTask?.value
        summaryTask = nil
    }

    private func runSummaryLoop(modelID: String) async {
        defer { summaryActivity = .idle }

        summaryActivity = .loadingModel(progress: 0)
        let generator: any TextGenerator
        do {
            generator = try await textGeneratorProvider.generator(for: modelID) { @Sendable progress in
                Task { @MainActor [weak self] in
                    guard let self, case .loadingModel = summaryActivity else { return }
                    summaryActivity = .loadingModel(progress: progress)
                }
            }
        } catch {
            if !Task.isCancelled {
                summaryFailure = .modelLoading(error)
            }
            return
        }
        summaryActivity = .idle

        let summarizer = TopicSummarizer(generator: generator)
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: summaryInterval)
            } catch {
                return
            }

            summaryActivity = .summarizing
            let startedAt = clock.now
            do {
                if let topic = try await summarizer.update(with: transcript.finalLines) {
                    currentTopic = topic
                    lastSummaryDuration = startedAt.duration(to: clock.now)
                    summaryFailure = nil
                }
            } catch {
                if Task.isCancelled { return }
                summaryFailure = .summarization(error)
            }
            summaryActivity = .idle
        }
    }
}

extension MeetingSession {
    /// A session capturing the microphone and system audio, transcribing Japanese on device.
    public static func live() -> MeetingSession {
        MeetingSession(
            microphone: MicrophoneCapture(),
            systemAudio: SystemAudioCapture(),
            makeTranscriptionEngine: { AppleSpeechTranscriptionEngine(locale: Locale(identifier: "ja-JP")) },
            textGeneratorProvider: MLXTextGeneratorProvider(),
            summaryInterval: .seconds(30)
        )
    }
}
