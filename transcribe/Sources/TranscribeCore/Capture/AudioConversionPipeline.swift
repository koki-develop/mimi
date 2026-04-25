import AVFoundation
import CoreMedia
import Foundation

/// 入力 PCM buffer の format 変化検出、converter 作り直し、drain、capture time 推定、
/// chunk 生成を担当する状態機械。`AudioOutputTap` からの委譲先。
///
/// 設計メモ:
/// - `activeConverter` は `(converter, inputFormat)` の optional tuple。
///   両方一緒に nil/non-nil に保たれる invariant を型レベルで担保するため。
struct AudioConversionPipeline: Sendable {
  /// `consume` の戻り値。`AudioOutputTap` がそれぞれの非 nil をディスパッチする。
  struct ConsumeResult {
    let firstFormatLog: String?
    let warning: String?
    let drainedChunk: CapturedAudioChunk?
    let convertedChunk: CapturedAudioChunk?
  }

  /// `finish` の戻り値。
  struct FinishResult {
    let warning: String?
    let chunk: CapturedAudioChunk?
  }

  private var activeConverter: (converter: AudioSampleConverter, inputFormat: AVAudioFormat)?
  private var timingMapper = SampleBufferClockMapper()
  private var didLogFormat = false
  private var nextCaptureTime: Date?

  init() {}

  /// テスト用 init。preset した converter で開始したい場合に使う。
  /// `(converter, inputFormat)` ペアの invariant を崩さないため、両方とも non-Optional。
  init(converter: AudioSampleConverter, inputFormat: AVAudioFormat) {
    self.activeConverter = (converter, inputFormat)
  }

  mutating func consume(
    inputBuffer: AVAudioPCMBuffer,
    presentationTime: CMTime,
    fallbackDate: Date,
    source: AudioSource,
    targetFormat: AVAudioFormat,
    formatDescription: String,
    verbose: Bool
  ) -> ConsumeResult {
    let firstFormatLog: String?
    if verbose, !didLogFormat {
      didLogFormat = true
      let label = source == .mic ? "mic" : "sys"
      firstFormatLog = "[debug] first \(label) buffer: \(formatDescription)"
    } else {
      firstFormatLog = nil
    }

    do {
      var drainedChunk: CapturedAudioChunk?
      if !Self.isCompatible(inputBuffer.format, with: activeConverter?.inputFormat) {
        drainedChunk = try drain(source: source)
        nextCaptureTime = nil
        guard
          let newConverter = AudioSampleConverter(
            inputFormat: inputBuffer.format,
            outputFormat: targetFormat
          )
        else {
          throw AudioSampleConverterError.conversionFailed("failed to create converter")
        }
        activeConverter = (newConverter, inputBuffer.format)
      }

      let captureTime = timingMapper.captureTime(
        for: presentationTime,
        fallbackDate: fallbackDate
      )
      if nextCaptureTime == nil {
        nextCaptureTime = captureTime
      }
      let convertedSamples = try activeConverter?.converter.convertStreaming(inputBuffer) ?? []
      let convertedChunk =
        convertedSamples.isEmpty
        ? nil
        : makeChunk(
          source: source,
          samples: convertedSamples,
          captureTime: nextCaptureTime ?? captureTime
        )

      return ConsumeResult(
        firstFormatLog: firstFormatLog,
        warning: nil,
        drainedChunk: drainedChunk,
        convertedChunk: convertedChunk
      )
    } catch {
      return ConsumeResult(
        firstFormatLog: firstFormatLog,
        warning: "audio conversion failed for \(source.rawValue): \(error)",
        drainedChunk: nil,
        convertedChunk: nil
      )
    }
  }

  mutating func finish(source: AudioSource) -> FinishResult {
    do {
      let chunk = try drain(source: source)
      return FinishResult(warning: nil, chunk: chunk)
    } catch {
      return FinishResult(
        warning: "audio converter drain failed for \(source.rawValue): \(error)",
        chunk: nil
      )
    }
  }

  private mutating func drain(source: AudioSource) throws -> CapturedAudioChunk? {
    guard let active = activeConverter else { return nil }

    defer {
      self.activeConverter = nil
    }

    let drainedSamples = try active.converter.finish()
    guard let nextCaptureTime, !drainedSamples.isEmpty else { return nil }

    return makeChunk(source: source, samples: drainedSamples, captureTime: nextCaptureTime)
  }

  private mutating func makeChunk(
    source: AudioSource,
    samples: [Float],
    captureTime: Date
  ) -> CapturedAudioChunk {
    nextCaptureTime = captureTime.addingTimeInterval(Double(samples.count) / 16_000)
    return CapturedAudioChunk(
      source: source,
      samples: samples,
      captureTime: captureTime
    )
  }

  private static func isCompatible(_ lhs: AVAudioFormat, with rhs: AVAudioFormat?) -> Bool {
    guard let rhs else { return false }

    return lhs.commonFormat == rhs.commonFormat
      && lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.isInterleaved == rhs.isInterleaved
  }
}
