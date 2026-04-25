import Foundation
import Testing

@testable import TranscribeCore

/// Layer A characterization tests と新構造 unit tests で共有するテスト用 fakes。

/// テスト用 capture。`micChunks` / `systemChunks` / `diagnostics` を script で渡し、
/// `start()` 内で同期 yield する。
/// `autoFinishAfterStart: true` を指定すると `start()` の最後で全 continuation を
/// finish する (= consumer 先行終了 シナリオを deterministic に再現できる)。
/// `streamErrorOnTake` を渡すと `takeStreamError()` が 1 回だけそれを返す。
final class FakeCapture: CaptureProtocol, @unchecked Sendable {
  let micStream: AsyncStream<CapturedAudioChunk>
  let systemStream: AsyncStream<CapturedAudioChunk>
  let diagnosticStream: AsyncStream<CaptureDiagnostic>

  private let micContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let systemContinuation: AsyncStream<CapturedAudioChunk>.Continuation
  private let diagnosticContinuation: AsyncStream<CaptureDiagnostic>.Continuation

  private let micChunks: [CapturedAudioChunk]
  private let systemChunks: [CapturedAudioChunk]
  private let diagnostics: [CaptureDiagnostic]
  private let autoFinishAfterStart: Bool

  private let lock = NSLock()
  private var streamErrorPending: Error?

  init(
    micChunks: [CapturedAudioChunk] = [],
    systemChunks: [CapturedAudioChunk] = [],
    diagnostics: [CaptureDiagnostic] = [],
    streamErrorOnTake: Error? = nil,
    autoFinishAfterStart: Bool = false
  ) {
    self.micChunks = micChunks
    self.systemChunks = systemChunks
    self.diagnostics = diagnostics
    self.streamErrorPending = streamErrorOnTake
    self.autoFinishAfterStart = autoFinishAfterStart

    var micCont: AsyncStream<CapturedAudioChunk>.Continuation!
    var sysCont: AsyncStream<CapturedAudioChunk>.Continuation!
    var diagCont: AsyncStream<CaptureDiagnostic>.Continuation!
    self.micStream = AsyncStream(bufferingPolicy: .unbounded) { micCont = $0 }
    self.systemStream = AsyncStream(bufferingPolicy: .unbounded) { sysCont = $0 }
    self.diagnosticStream = AsyncStream(bufferingPolicy: .unbounded) { diagCont = $0 }
    self.micContinuation = micCont
    self.systemContinuation = sysCont
    self.diagnosticContinuation = diagCont
  }

  func start() async throws {
    for chunk in micChunks { micContinuation.yield(chunk) }
    for chunk in systemChunks { systemContinuation.yield(chunk) }
    for d in diagnostics { diagnosticContinuation.yield(d) }
    if autoFinishAfterStart {
      micContinuation.finish()
      systemContinuation.finish()
      diagnosticContinuation.finish()
    }
  }

  func stop() async {
    micContinuation.finish()
    systemContinuation.finish()
    diagnosticContinuation.finish()
  }

  func takeStreamError() -> Error? {
    lock.lock()
    defer { lock.unlock() }
    let err = streamErrorPending
    streamErrorPending = nil
    return err
  }
}

/// テスト用 transcriber。input ストリームを drain して scripted な `Segment` 列を yield する。
/// `nil` を渡すと segment は出さず input が drain しきった時点で終了する。
final class FakeTranscriber: TranscriberProtocol, @unchecked Sendable {
  private let segments: [Segment]

  init(segments: [Segment] = []) {
    self.segments = segments
  }

  func consume(_ input: AsyncStream<CapturedAudioChunk>) -> AsyncStream<Segment> {
    let segments = self.segments
    return AsyncStream(bufferingPolicy: .unbounded) { continuation in
      Task {
        for await _ in input {
          // 入力チャンクを drain するだけ。
        }
        for seg in segments { continuation.yield(seg) }
        continuation.finish()
      }
    }
  }
}

/// テスト用 transcriber factory。pre-built fake transcribers を返す。
struct FakeTranscriberFactory: TranscriberFactory {
  let mic: any TranscriberProtocol
  let system: any TranscriberProtocol

  func makeTranscribers(
    modelName: String,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) async throws -> (mic: any TranscriberProtocol, system: any TranscriberProtocol) {
    return (mic: mic, system: system)
  }
}

/// テスト用 signal waiter。`trigger()` を呼ぶまで suspend し続ける。
/// `withTaskCancellationHandler` で cancellation 伝播も尊重する。
final class ControllableSignalWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var resumed = false

  /// SIGINT 待ちの代わり。`trigger()` か Task キャンセルで復帰。
  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        lock.lock()
        if resumed {
          lock.unlock()
          cont.resume()
        } else {
          continuation = cont
          lock.unlock()
        }
      }
    } onCancel: {
      trigger()
    }
  }

  /// SIGINT を「投げる」。
  func trigger() {
    lock.lock()
    let cont = continuation
    continuation = nil
    let alreadyResumed = resumed
    resumed = true
    lock.unlock()
    if !alreadyResumed { cont?.resume() }
  }
}
