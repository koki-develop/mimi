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
/// 新 protocol (loadModels + makeTranscribers) に合わせて 2 段化。
/// `loadModels` は `LoadedModels.testingPlaceholder` を返し、`makeTranscribers` は
/// 中身を一切参照せず事前に渡された fake transcribers をそのまま返す。
struct FakeTranscriberFactory: TranscriberFactory {
  let mic: any TranscriberProtocol
  let system: any TranscriberProtocol
  /// `loadModels` が throw すべきならここに set。
  var loadError: Error?

  func loadModels(modelName: String, logger: EventLogger) async throws -> LoadedModels {
    if let loadError { throw loadError }
    return .testingPlaceholder
  }

  func makeTranscribers(
    models: LoadedModels,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) -> (mic: any TranscriberProtocol, system: any TranscriberProtocol) {
    return (mic: mic, system: system)
  }
}

/// テスト用 `EventSink`。受け取ったイベントを順序通り内部に貯める。
/// EventLoggerTests / TranscribeDaemonTests から共有して使う。
/// Swift 6 の strict concurrency 下では async 関数内で NSLock.lock/unlock を呼べないので、
/// 排他処理は private な sync ヘルパに閉じ込めて async API はそれを呼ぶだけにする。
final class RecordingEventSink: EventSink, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [Event] = []
  private var closed = false

  private func writeSync(_ event: Event) throws {
    lock.lock()
    defer { lock.unlock() }
    if closed { throw RecordingEventSinkError.closed }
    events.append(event)
  }

  private func closeSync() {
    lock.lock()
    defer { lock.unlock() }
    closed = true
  }

  func write(_ event: Event) async throws {
    try writeSync(event)
  }

  func close() async throws {
    closeSync()
  }

  func recordedEvents() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

enum RecordingEventSinkError: Error, Equatable {
  case closed
}

/// `TranscribeDaemon` テスト用 factory。`loadModels` は `LoadedModels.testingPlaceholder`
/// を返す (中身は nil kit + 名前のみの sentinel)。`makeTranscribers` の戻り値は
/// 事前に渡された fake transcribers をそのまま返すので、`LoadedModels` の中身は
/// 一切参照されない。
/// `loadCount` で「daemon は boot 時に 1 度だけ loadModels を呼ぶ」不変条件を検証できる。
struct PreloadedTranscriberFactory: TranscriberFactory {
  let mic: any TranscriberProtocol
  let system: any TranscriberProtocol
  var loadError: Error?
  let loadCount = Counter()

  func loadModels(modelName: String, logger: EventLogger) async throws -> LoadedModels {
    loadCount.increment()
    if let loadError { throw loadError }
    return .testingPlaceholder
  }

  func makeTranscribers(
    models: LoadedModels,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) -> (mic: any TranscriberProtocol, system: any TranscriberProtocol) {
    return (mic: mic, system: system)
  }
}

/// テスト用カウンタ (Sendable)。`PreloadedTranscriberFactory.loadCount` で
/// 「daemon が boot 時 1 度だけモデルロードする」を検証するための回数記録。
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  func current() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
