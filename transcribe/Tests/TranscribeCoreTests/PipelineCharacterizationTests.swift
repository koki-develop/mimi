import Foundation
import Testing

@testable import TranscribeCore

/// Layer A characterization test。`Pipeline.run` の外側振る舞いを
/// JSONL event 列レベルで固定する。
///
/// 4 シナリオ:
///   1. 正常 SIGINT 停止
///   2. capture 中 stream error
///   3. permission 拒否で開始前 fail (screenRecordingDenied)
///   4. output ファイル既存で fail
@Suite struct PipelineCharacterizationTests {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "transcribe-char-\(UUID().uuidString).jsonl")
  }

  /// 1 行 1 Event として decode する helper。
  private func decodeEvents(from url: URL) throws -> [Event] {
    let content = try String(contentsOf: url, encoding: .utf8)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let decoder = JSONDecoder()
    return try lines.map { line in
      try decoder.decode(Event.self, from: Data(line.utf8))
    }
  }

  private func defaultDeps(
    permissionCheck: @escaping @Sendable () async throws -> Void = {},
    transcriberFactory: any TranscriberFactory = FakeTranscriberFactory(
      mic: FakeTranscriber(), system: FakeTranscriber()),
    captureFactory: @escaping @Sendable (Bool) -> any CaptureProtocol,
    signalWaiter: @escaping @Sendable () async -> Void = {
      await ControllableSignalWaiter().wait()  // 永久待ち
    },
    writerFactory: @escaping @Sendable (URL) throws -> JSONLWriter = { url in
      try JSONLWriter(output: url)
    }
  ) -> PipelineDependencies {
    PipelineDependencies(
      permissionCheck: permissionCheck,
      transcriberFactory: transcriberFactory,
      captureFactory: captureFactory,
      signalWaiter: signalWaiter,
      writerFactory: writerFactory
    )
  }

  // MARK: - Scenario 1: 正常 SIGINT 停止

  @Test func sigintStopProducesExpectedEventSequence() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    let signalWaiter = ControllableSignalWaiter()
    let fakeCapture = FakeCapture()

    let deps = defaultDeps(
      captureFactory: { _ in fakeCapture },
      signalWaiter: { await signalWaiter.wait() }
    )

    // ControllableSignalWaiter は事前 trigger を「resumed フラグ」として記憶するので、
    // pipeline.run() より前に trigger() を呼んでも問題ない (race-free、deterministic)。
    signalWaiter.trigger()

    let pipeline = Pipeline(
      configuration: PipelineConfiguration(output: output, modelName: "test-model"),
      dependencies: deps
    )
    try await pipeline.run()

    // session_started → state_changed(loading_model) → state_changed(capturing)
    //   → state_changed(stopping) → session_stopped(.sigint)
    let events = try decodeEvents(from: output)
    #expect(events.count == 5)

    if case .sessionStarted(_, let data) = events[0] {
      #expect(data.model == "test-model")
    } else {
      Issue.record("expected session_started")
    }
    if case .stateChanged(_, let data) = events[1], data.state == .loadingModel {
    } else {
      Issue.record("expected loading_model")
    }
    if case .stateChanged(_, let data) = events[2], data.state == .capturing {
    } else {
      Issue.record("expected capturing")
    }
    if case .stateChanged(_, let data) = events[3], data.state == .stopping {
    } else {
      Issue.record("expected stopping")
    }
    if case .sessionStopped(_, let data) = events[4], data.reason == .sigint {
    } else {
      Issue.record("expected session_stopped(.sigint)")
    }

    for i in 1..<events.count {
      #expect(events[i - 1].timestamp <= events[i].timestamp)
    }
  }

  // MARK: - Scenario 2: capture stream error

  @Test func captureStreamErrorProducesErrorAndStoppedError() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    struct FakeError: Error, Equatable {}

    // capture.start() の最後で stream を即座に finish させる (= consumer 先行終了 を再現)。
    // takeStreamError() で FakeError が返り、Pipeline は error event + sessionStopped(.error) を発行する。
    let fakeCapture = FakeCapture(
      streamErrorOnTake: FakeError(),
      autoFinishAfterStart: true
    )

    let deps = defaultDeps(
      captureFactory: { _ in fakeCapture }
    )

    let pipeline = Pipeline(
      configuration: PipelineConfiguration(output: output, modelName: "test-model"),
      dependencies: deps
    )

    // stream error 発生時は CLI が non-zero exit code を返す (PipelineError.captureFailed)。
    // JSONL は同時に error event + sessionStopped(.error) を発行している。
    await #expect(throws: PipelineError.captureFailed(reason: "FakeError()")) {
      try await pipeline.run()
    }

    let events = try decodeEvents(from: output)
    // session_started → state_changed(loading_model) → state_changed(capturing)
    //   → error → session_stopped(.error)
    #expect(events.count == 5)

    if case .sessionStarted = events[0] {} else { Issue.record("expected session_started") }
    if case .stateChanged(_, let d) = events[1], d.state == .loadingModel {
    } else {
      Issue.record("expected loading_model")
    }
    if case .stateChanged(_, let d) = events[2], d.state == .capturing {
    } else {
      Issue.record("expected capturing")
    }
    if case .error(_, let d) = events[3] {
      #expect(d.message.contains("Capture stopped unexpectedly"))
    } else {
      Issue.record("expected error event")
    }
    if case .sessionStopped(_, let d) = events[4], d.reason == .error {
    } else {
      Issue.record("expected session_stopped(.error)")
    }
  }

  // MARK: - Scenario 3: permission denied (screen)

  @Test func screenRecordingDeniedEmitsErrorAndSessionStopped() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    let deps = defaultDeps(
      permissionCheck: { throw PermissionError.screenRecordingDenied },
      captureFactory: { _ in
        fatalError("captureFactory must not be called when permission is denied")
      },
      signalWaiter: {
        fatalError("signalWaiter must not be called when permission is denied")
      }
    )

    await #expect(throws: PipelineError.permissionDenied(.screenRecordingDenied)) {
      let pipeline = Pipeline(
        configuration: PipelineConfiguration(output: output, modelName: "test-model"),
        dependencies: deps
      )
      try await pipeline.run()
    }

    let events = try decodeEvents(from: output)
    #expect(events.count == 3)

    if case .sessionStarted(_, let data) = events[0] {
      #expect(data.model == "test-model")
    } else {
      Issue.record("expected session_started")
    }
    if case .error(_, let data) = events[1] {
      #expect(data.message == "Screen Recording permission required.")
    } else {
      Issue.record("expected error")
    }
    if case .sessionStopped(_, let data) = events[2], data.reason == .error {
    } else {
      Issue.record("expected session_stopped(.error)")
    }

    #expect(events[0].timestamp <= events[1].timestamp)
    #expect(events[1].timestamp <= events[2].timestamp)
  }

  // MARK: - Scenario 4: output already exists

  @Test func outputAlreadyExistsThrowsBeforeAnyOtherCalls() async throws {
    let output = tempURL()
    defer { try? FileManager.default.removeItem(at: output) }

    let deps = defaultDeps(
      permissionCheck: {
        fatalError("permissionCheck must not be called when output already exists")
      },
      captureFactory: { _ in
        fatalError("captureFactory must not be called when output already exists")
      },
      signalWaiter: {
        fatalError("signalWaiter must not be called when output already exists")
      },
      writerFactory: { _ in throw JSONLWriterError.outputAlreadyExists }
    )

    await #expect(throws: PipelineError.outputAlreadyExists(path: output.path)) {
      let pipeline = Pipeline(
        configuration: PipelineConfiguration(output: output, modelName: "test-model"),
        dependencies: deps
      )
      try await pipeline.run()
    }

    #expect(!FileManager.default.fileExists(atPath: output.path))
  }
}
