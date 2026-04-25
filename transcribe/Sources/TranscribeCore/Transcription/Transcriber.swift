import Foundation
@preconcurrency import WhisperKit

public actor Transcriber: TranscriberProtocol {
  private static let sampleRate: Double = 16_000

  private let source: AudioSource
  private let kit: WhisperKit
  private let reporter: EventLogger
  private let verbose: Bool
  private let configuration: TranscriberConfiguration
  private let vad: EnergyVAD
  private let windowSamples: Int

  private var windowIndex: Int = 0
  private var lastEmittedText: String = ""

  init(
    source: AudioSource,
    model: LoadedModel,
    reporter: EventLogger,
    configuration: TranscriberConfiguration,
    verbose: Bool = false
  ) {
    self.source = source
    self.kit = model.kit
    self.reporter = reporter
    self.verbose = verbose
    self.configuration = configuration
    self.windowSamples = Int(Self.sampleRate * configuration.windowSeconds)
    self.vad = EnergyVAD(
      sampleRate: Int(Self.sampleRate),
      frameLength: 0.1,
      frameOverlap: 0.0,
      energyThreshold: configuration.energyThreshold
    )
  }

  public nonisolated func consume(_ input: AsyncStream<CapturedAudioChunk>) -> AsyncStream<Segment>
  {
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
      while let window = accumulator.popWindow(sampleCount: windowSamples) {
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
      let rms =
        samples.isEmpty
        ? 0.0 : sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
      let label = source == .mic ? "mic" : "sys"
      await reporter.statusMessage(
        String(
          format: "[debug] %@ window=%d samples=%d rms=%.4f voice=%.1f%%",
          label,
          windowIndex,
          samples.count,
          Double(rms),
          voiceRatio * 100
        ))
    }
    guard voiceRatio >= configuration.voiceActivityThreshold else { return }

    do {
      let options = DecodingOptions(
        task: .transcribe,
        language: configuration.language,
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

          continuation.yield(
            Segment(
              source: source,
              timestamp: timestamp,
              duration: (duration * 1_000).rounded() / 1_000,
              text: trimmed
            ))
        }
      }
    } catch is CancellationError {
      // シャットダウン経路で cancelAll() 経由に kit.transcribe がキャンセルされた場合は
      // ノイズ(spurious warning flood)を避けるため silent に return する。
      return
    } catch {
      await reporter.warning("transcription failed for \(source.rawValue): \(error)")
    }
  }
}
