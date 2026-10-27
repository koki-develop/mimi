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
    /// When the session started running. Set while the session is running or stopping.
    public private(set) var runningSince: Date?
    public private(set) var transcript = Transcript()
    public private(set) var currentTopic = ""
    public private(set) var summaryActivity = SummaryActivity.idle
    /// The reason the last session failed to start or stopped unexpectedly.
    public private(set) var failure: Failure?
    public private(set) var summaryFailure: SummaryFailure?
    /// Whether the microphone is excluded from capture. Applies to the current and later sessions.
    public private(set) var isMicrophoneMuted = false

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
    @ObservationIgnored private var microphoneEngine: (any TranscriptionEngine)?
    @ObservationIgnored private var isMicrophoneCapturing = false
    @ObservationIgnored private var microphoneReconciliation: Task<Void, Never>?
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

    /// Mutes or unmutes the microphone. ``isMicrophoneMuted`` changes immediately; capture stops or resumes in
    /// the background, in call order. When muting, the speech captured before muting is finalized.
    /// - Returns: A task that completes once capture follows this call.
    @discardableResult
    public func setMicrophoneMuted(_ muted: Bool) -> Task<Void, Never> {
        isMicrophoneMuted = muted
        return reconcileMicrophone()
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
            runningSince = nil
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStart(summaryModelID: String) async {
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
        runningSince = .now
        summaryTask = Task { [self] in await runSummaryLoop(modelID: summaryModelID) }
    }

    private func startCapture() async throws(Failure) {
        let timelineOrigin = mach_absolute_time()

        microphoneEngine = try await startEngine(for: .me, timelineOrigin: timelineOrigin)
        // Starts the microphone unless muted. Failures are recorded and checked by `performStart`.
        await reconcileMicrophone().value

        let systemAudioEngine = try await startEngine(for: .others, timelineOrigin: timelineOrigin)
        try start(systemAudio, feeding: systemAudioEngine, meter: systemAudioLevel)
    }

    private func startEngine(for speaker: Speaker, timelineOrigin: UInt64) async throws(Failure) -> any TranscriptionEngine {
        let engine = makeTranscriptionEngine()
        engines.append(engine)
        do {
            observe(try await engine.start(timelineOrigin: timelineOrigin), from: speaker)
        } catch {
            throw .transcription(error)
        }
        return engine
    }

    private func stopMicrophone() {
        microphone.stop()
        isMicrophoneCapturing = false
        microphoneLevel.reset()
    }

    private func start(_ source: any AudioSource, feeding engine: any TranscriptionEngine, meter: AudioLevelMeter) throws(Failure) {
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

    /// Schedules bringing microphone capture in line with ``isMicrophoneMuted``. This is the only path that
    /// starts or stops the microphone while a session is active, and runs one at a time in call order.
    private func reconcileMicrophone() -> Task<Void, Never> {
        let previous = microphoneReconciliation
        let task = Task { [self] in
            await previous?.value
            await applyMicrophoneMute()
        }
        microphoneReconciliation = task
        return task
    }

    private func applyMicrophoneMute() async {
        guard isCaptureActive, let microphoneEngine else { return }
        if isMicrophoneMuted, isMicrophoneCapturing {
            stopMicrophone()
            await microphoneEngine.finalizePending()
        } else if !isMicrophoneMuted, !isMicrophoneCapturing {
            let isAccessGranted = await microphone.requestAccess()
            // The session may have stopped, or a new one started, while access was being requested.
            guard isCaptureActive, self.microphoneEngine === microphoneEngine else { return }
            guard isAccessGranted else {
                fail(.microphoneAccessDenied)
                return
            }
            // Muting while access was being requested takes precedence.
            guard !isMicrophoneMuted else { return }
            do {
                try start(microphone, feeding: microphoneEngine, meter: microphoneLevel)
                isMicrophoneCapturing = true
            } catch {
                fail(error)
            }
        }
    }

    private var isCaptureActive: Bool {
        state == .starting || state == .running
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
        stopMicrophone()
        systemAudio.stop()
        await withTaskGroup { group in
            for engine in engines {
                group.addTask { await engine.finish() }
            }
        }
        engines = []
        microphoneEngine = nil
        for task in resultTasks {
            await task.value
        }
        resultTasks = []
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
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: summaryInterval)
            } catch {
                return
            }

            summaryActivity = .summarizing
            do {
                if let topic = try await summarizer.update(with: transcript.finalLines) {
                    currentTopic = topic
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
