import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// `SCStreamOutput` に conform して 1 source 分の audio buffer を受け取り、
/// `AudioConversionPipeline` に委譲して `CapturedAudioChunk` を継続に流す。
///
/// `CaptureDiagnostic` 経由の同期 yield に揃えてある。これにより writer 閉鎖後に
/// actor hop で silent failure になる shutdown race が構造的に発生しない。
final class AudioOutputTap: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue: DispatchQueue

  private let source: AudioSource
  private let continuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation
  private let verbose: Bool
  private let targetFormat: AVAudioFormat
  private let sessionStart: SessionStartTracker

  private let stateLock = NSLock()
  private var state = AudioConversionPipeline()

  init(
    source: AudioSource,
    continuation: AsyncStream<CapturedAudioChunk>.Continuation,
    diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation,
    verbose: Bool,
    sessionStart: SessionStartTracker
  ) {
    self.queue = DispatchQueue(
      label: "me.koki.transcribe.capture.\(source.rawValue)",
      qos: .userInitiated
    )
    self.source = source
    self.continuation = continuation
    self.diagnosticContinuation = diagnosticContinuation
    self.verbose = verbose
    self.sessionStart = sessionStart
    self.targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )!
  }

  func finish() {
    let result = withLockedState { state in
      state.finish(source: source)
    }

    if let warning = result.warning {
      diagnosticContinuation.yield(.warning(source: source, message: warning))
    }
    if let trailingChunk = result.chunk {
      continuation.yield(trailingChunk)
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard sampleBuffer.isValid, Self.matches(source: source, outputType: type) else {
      return
    }
    guard let inputBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

    let now = Date()
    let formatDescription = Self.describe(format: inputBuffer.format)
    let presentationTime = Self.capturePresentationTime(from: sampleBuffer)

    let result = withLockedState { state in
      state.consume(
        inputBuffer: inputBuffer,
        presentationTime: presentationTime,
        fallbackDate: now,
        source: source,
        targetFormat: targetFormat,
        formatDescription: formatDescription,
        verbose: verbose
      )
    }

    if let firstFormatLog = result.firstFormatLog {
      diagnosticContinuation.yield(.status(message: firstFormatLog))
    }
    if let warning = result.warning {
      diagnosticContinuation.yield(.warning(source: source, message: warning))
    }
    if let drainedChunk = result.drainedChunk {
      sessionStart.recordCaptureTime(drainedChunk.captureTime)
      continuation.yield(drainedChunk)
    }
    if let convertedChunk = result.convertedChunk {
      sessionStart.recordCaptureTime(convertedChunk.captureTime)
      continuation.yield(convertedChunk)
    }
  }

  private func withLockedState<T>(_ body: (inout AudioConversionPipeline) -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body(&state)
  }

  static func matches(source: AudioSource, outputType: SCStreamOutputType) -> Bool {
    switch (source, outputType) {
    case (.system, .audio), (.mic, .microphone):
      return true
    default:
      return false
    }
  }

  static func capturePresentationTime(from sampleBuffer: CMSampleBuffer) -> CMTime {
    let outputTime = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
    if outputTime.isValid, !outputTime.isIndefinite {
      return outputTime
    }

    return CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
  }

  static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
      return nil
    }
    let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

    let sampleCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard sampleCount > 0 else { return nil }
    guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount) else {
      return nil
    }

    pcmBuffer.frameLength = sampleCount

    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(sampleCount),
      into: pcmBuffer.mutableAudioBufferList
    )
    guard status == noErr else { return nil }

    return pcmBuffer
  }

  static func describe(format: AVAudioFormat) -> String {
    "\(Int(format.sampleRate))Hz, \(format.channelCount)ch, format=\(format.commonFormat.rawValue)"
  }
}
