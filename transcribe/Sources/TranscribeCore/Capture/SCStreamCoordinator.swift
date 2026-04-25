import Foundation
import ScreenCaptureKit

/// `SCStreamDelegate` の実装と、shutdown 時の continuation finish 順序を所有する。
///
/// `stream(_:didStopWithError:)` で予期せぬエラーを `streamErrorBox` に同期記録し、
/// その後 `finish()` で各種 continuation を冪等に閉じる。
final class SCStreamCoordinator: NSObject, SCStreamDelegate, @unchecked Sendable {
  private let micOutput: AudioOutputTap
  private let systemOutput: AudioOutputTap
  private let micContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation
  private let streamErrorBox: StreamErrorBox

  private let finishLock = NSLock()
  private var hasFinished = false

  init(
    streamErrorBox: StreamErrorBox,
    micOutput: AudioOutputTap,
    systemOutput: AudioOutputTap,
    micContinuation: AsyncStream<CapturedAudioChunk>.Continuation,
    systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation,
    diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation
  ) {
    self.streamErrorBox = streamErrorBox
    self.micOutput = micOutput
    self.systemOutput = systemOutput
    self.micContinuation = micContinuation
    self.systemContinuation = systemContinuation
    self.diagnosticContinuation = diagnosticContinuation
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    // エラーを同期的に box に保管し、Pipeline.run が group drain 後に取り出して
    // `error` イベントを本流で emit する。fire-and-forget Task だと
    // writer close との race で JSONL から event が消える可能性があるため。
    streamErrorBox.trySet(error)
    finish()
  }

  func finish() {
    finishLock.lock()
    let shouldFinish = !hasFinished
    hasFinished = true
    finishLock.unlock()

    guard shouldFinish else { return }

    micOutput.finish()
    systemOutput.finish()
    micContinuation.finish()
    systemContinuation.finish()
    diagnosticContinuation.finish()
  }
}
