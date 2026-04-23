import Foundation
@preconcurrency import WhisperKit

public protocol TranscriberProtocol: Sendable {
    func consume(_ input: AsyncStream<CapturedAudioChunk>) -> AsyncStream<Segment>
}

public actor Transcriber: TranscriberProtocol {
    private static let sampleRate: Double = 16_000
    private static let windowSeconds: Double = 5.0
    private static let windowSamples: Int = Int(sampleRate * windowSeconds)
    private static let voiceActivityThreshold: Double = 0.1
    private static let energyThreshold: Float = 0.005

    private let source: AudioSource
    private let kit: WhisperKit
    private let reporter: ConsoleReporter
    private let verbose: Bool
    private let vad: EnergyVAD

    private var windowIndex: Int = 0
    private var lastEmittedText: String = ""

    public init(
        source: AudioSource,
        model: LoadedModel,
        reporter: ConsoleReporter,
        verbose: Bool = false
    ) {
        self.source = source
        self.kit = model.kit
        self.reporter = reporter
        self.verbose = verbose
        self.vad = EnergyVAD(
            sampleRate: Int(Self.sampleRate),
            frameLength: 0.1,
            frameOverlap: 0.0,
            energyThreshold: Self.energyThreshold
        )
    }

    public nonisolated func consume(_ input: AsyncStream<CapturedAudioChunk>) -> AsyncStream<Segment> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.runPipeline(input: input, continuation: continuation)
            }
        }
    }

    private func runPipeline(
        input: AsyncStream<CapturedAudioChunk>,
        continuation: AsyncStream<Segment>.Continuation
    ) async {
        var accumulator = TimedSampleAccumulator(sampleRate: Self.sampleRate)

        for await chunk in input {
            accumulator.append(chunk)
            while let window = accumulator.popWindow(sampleCount: Self.windowSamples) {
                await transcribeWindow(
                    window.samples,
                    windowStart: window.startTime,
                    continuation: continuation
                )
            }
        }

        if let finalWindow = accumulator.finish() {
            await transcribeWindow(
                finalWindow.samples,
                windowStart: finalWindow.startTime,
                continuation: continuation
            )
        }

        continuation.finish()
    }

    private func transcribeWindow(
        _ samples: [Float],
        windowStart: Date,
        continuation: AsyncStream<Segment>.Continuation
    ) async {
        let activity = vad.voiceActivity(in: samples)
        let voiceFrames = activity.filter { $0 }.count
        let voiceRatio = Double(voiceFrames) / Double(max(activity.count, 1))
        windowIndex += 1

        if verbose {
            let rms = samples.isEmpty ? 0.0 : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
            let label = source == .mic ? "mic" : "sys"
            await reporter.reportStatus(String(
                format: "[debug] %@ window=%d samples=%d rms=%.4f voice=%.1f%%",
                label,
                windowIndex,
                samples.count,
                Double(rms),
                voiceRatio * 100
            ))
        }
        guard voiceRatio >= Self.voiceActivityThreshold else { return }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "ja",
                skipSpecialTokens: true,
                withoutTimestamps: false,
                suppressBlank: true,
                noSpeechThreshold: 0.4
            )
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            for result in results {
                for segment in result.segments {
                    let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if trimmed == lastEmittedText { continue }
                    lastEmittedText = trimmed

                    let startInWindow = Double(segment.start)
                    let duration = Double(segment.end - segment.start)
                    let timestamp = windowStart.addingTimeInterval(startInWindow)

                    continuation.yield(Segment(
                        source: source,
                        timestamp: timestamp,
                        duration: (duration * 1_000).rounded() / 1_000,
                        text: trimmed
                    ))
                }
            }
        } catch {
            await reporter.reportWarning("transcription failed for \(source.rawValue): \(error)")
        }
    }
}
