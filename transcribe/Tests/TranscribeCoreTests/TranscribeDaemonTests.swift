import Foundation
import Testing

@testable import TranscribeCore

@Suite("TranscribeDaemon")
struct TranscribeDaemonTests {
  // --- helpers ---

  /// 与えられた `commands` を yield して closure を呼ぶ AsyncStream を返す。
  /// closure 完了で stream 終了 = stdin EOF 相当。
  private func sourceFactory(
    _ commands: [CommandSourceItem]
  ) -> @Sendable () -> AsyncStream<CommandSourceItem> {
    {
      AsyncStream { continuation in
        for c in commands { continuation.yield(c) }
        continuation.finish()
      }
    }
  }

  private func runDaemon(
    commands: [CommandSourceItem],
    permission: @escaping @Sendable () async throws -> Void = {},
    capture: any CaptureProtocol = FakeCapture(autoFinishAfterStart: true),
    transcriberFactory: any TranscriberFactory = PreloadedTranscriberFactory(
      mic: FakeTranscriber(),
      system: FakeTranscriber()
    ),
    sink: RecordingEventSink = RecordingEventSink(),
    micEnabledState: MicEnabledState = MicEnabledState()
  ) async throws -> RecordingEventSink {
    let daemon = TranscribeDaemon(
      configuration: DaemonConfiguration(modelName: "test-model"),
      dependencies: DaemonDependencies(
        permissionCheck: permission,
        transcriberFactory: transcriberFactory,
        captureFactory: { _, _ in capture },
        eventSink: sink,
        commandSource: sourceFactory(commands)
      ),
      micEnabledState: micEnabledState
    )
    try await daemon.run()
    return sink
  }

  // --- boot ---

  @Test("boot emits loading_model then ready, then exits cleanly on stdin EOF")
  func bootEmitsLoadingThenReady() async throws {
    let sink = try await runDaemon(commands: [])
    let states = sink.recordedEvents().compactMap { event -> State? in
      if case .stateChanged(_, let data) = event { return data.state }
      return nil
    }
    #expect(states == [.loadingModel, .ready])
  }

  @Test("model load failure emits fatal and throws DaemonError.modelLoadFailed")
  func modelLoadFailureEmitsFatal() async throws {
    let sink = RecordingEventSink()
    let factory = PreloadedTranscriberFactory(
      mic: FakeTranscriber(),
      system: FakeTranscriber(),
      loadError: NSError(domain: "TestError", code: 42)
    )
    let daemon = TranscribeDaemon(
      configuration: DaemonConfiguration(modelName: "nonexistent"),
      dependencies: DaemonDependencies(
        permissionCheck: {},
        transcriberFactory: factory,
        captureFactory: { _, _ in FakeCapture() },
        eventSink: sink,
        commandSource: sourceFactory([])
      )
    )
    do {
      try await daemon.run()
      Issue.record("expected throw, got nothing")
    } catch let e as DaemonError {
      if case .modelLoadFailed = e {
        // OK — wrapped reason is non-deterministic NSError formatting; case-only match.
      } else {
        Issue.record("expected DaemonError.modelLoadFailed, got \(e)")
      }
    } catch {
      Issue.record("expected DaemonError, got \(error)")
    }
    let states = sink.recordedEvents().compactMap { event -> State? in
      if case .stateChanged(_, let data) = event { return data.state }
      return nil
    }
    #expect(states.first == .loadingModel)
    #expect(states.contains(.fatal))
    #expect(!states.contains(.ready))
  }

  @Test("loadModels is invoked exactly once across many sessions")
  func loadModelsCalledOncePerDaemon() async throws {
    let factory = PreloadedTranscriberFactory(
      mic: FakeTranscriber(),
      system: FakeTranscriber()
    )
    let sink = RecordingEventSink()
    let daemon = TranscribeDaemon(
      configuration: DaemonConfiguration(modelName: "test-model"),
      dependencies: DaemonDependencies(
        permissionCheck: {},
        transcriberFactory: factory,
        captureFactory: { _, _ in FakeCapture(autoFinishAfterStart: true) },
        eventSink: sink,
        commandSource: sourceFactory([
          .command(.start), .command(.stop),
          .command(.start), .command(.stop),
          .command(.start), .command(.stop),
        ])
      )
    )
    try await daemon.run()
    #expect(factory.loadCount.current() == 1)
  }

  // --- start ---

  @Test("start cmd emits session_started + state_changed:capturing")
  func startEmitsSessionStartedAndCapturing() async throws {
    let sink = try await runDaemon(commands: [
      .command(.start),
      .command(.stop),
    ])
    let kinds = sink.recordedEvents().map { $0.typeString }
    #expect(kinds.contains("session_started"))
    let states = sink.recordedEvents().compactMap { event -> State? in
      if case .stateChanged(_, let data) = event { return data.state }
      return nil
    }
    // expected order: loading_model, ready, capturing, stopping, ready
    #expect(states == [.loadingModel, .ready, .capturing, .stopping, .ready])
  }

  @Test("start while already capturing emits error, no state change")
  func startWhileCapturingEmitsError() async throws {
    let sink = try await runDaemon(commands: [
      .command(.start),
      .command(.start),  // second start -> error
      .command(.stop),
    ])
    let errorMessages = sink.recordedEvents().compactMap { event -> String? in
      if case .error(_, let data) = event { return data.message }
      return nil
    }
    #expect(errorMessages.contains("already recording"))
  }

  @Test("permission denial emits error, stays in ready (no session_started)")
  func permissionDenialEmitsErrorStaysReady() async throws {
    let sink = try await runDaemon(
      commands: [.command(.start)],
      permission: { throw PermissionError.microphoneDenied }
    )
    let kinds = sink.recordedEvents().map { $0.typeString }
    #expect(!kinds.contains("session_started"))
    let states = sink.recordedEvents().compactMap { event -> State? in
      if case .stateChanged(_, let data) = event { return data.state }
      return nil
    }
    #expect(states == [.loadingModel, .ready])
    #expect(kinds.contains("error"))
  }

  // --- stop ---

  @Test("stop while idle emits error")
  func stopWhileIdleEmitsError() async throws {
    let sink = try await runDaemon(commands: [.command(.stop)])
    let errors = sink.recordedEvents().compactMap { event -> String? in
      if case .error(_, let data) = event { return data.message }
      return nil
    }
    #expect(errors.contains("not recording"))
  }

  @Test("stop after start emits stopping → session_stopped(stop) → ready")
  func stopEmitsCleanShutdown() async throws {
    let sink = try await runDaemon(commands: [
      .command(.start),
      .command(.stop),
    ])
    let stopReason = sink.recordedEvents().compactMap { event -> StopReason? in
      if case .sessionStopped(_, let data) = event { return data.reason }
      return nil
    }.first
    #expect(stopReason == .stop)
  }

  // --- protocol violations ---

  @Test("parse error emits error event, daemon stays alive")
  func parseErrorEmitsError() async throws {
    let sink = try await runDaemon(commands: [
      .parseError(rawLine: "garbage"),
      .command(.start),
      .command(.stop),
    ])
    let errors = sink.recordedEvents().compactMap { event -> String? in
      if case .error(_, let data) = event { return data.message }
      return nil
    }
    #expect(errors.contains { $0.contains("garbage") })
    let kinds = sink.recordedEvents().map { $0.typeString }
    #expect(kinds.contains("session_started"))
  }

  // --- mid-session capture error ---

  @Test("capture stream error mid-session emits session_stopped(error) and returns to ready")
  func captureStreamErrorEndsSessionWithErrorReason() async throws {
    struct FakeStreamError: Error {}
    // FakeCapture with streamErrorOnTake + autoFinishAfterStart simulates a
    // capture that errors immediately after start (consumer streams EOF and the
    // delegate-side stream error gets surfaced via takeStreamError()).
    let capture = FakeCapture(
      streamErrorOnTake: FakeStreamError(),
      autoFinishAfterStart: true
    )
    let sink = try await runDaemon(
      // Only one start. No stop. The session should end on its own (capture
      // errors), the daemon should emit session_stopped(.error) + state_changed(.ready),
      // then exit cleanly on stdin EOF without an external stop.
      commands: [.command(.start)],
      capture: capture
    )

    let stopReasons = sink.recordedEvents().compactMap { event -> StopReason? in
      if case .sessionStopped(_, let data) = event { return data.reason }
      return nil
    }
    #expect(stopReasons == [.error])

    // Verify daemon returned to ready after the self-completion. There should be
    // exactly two `ready` state transitions: the boot one and the post-session one.
    let states = sink.recordedEvents().compactMap { event -> State? in
      if case .stateChanged(_, let data) = event { return data.state }
      return nil
    }
    let readyCount = states.filter { $0 == .ready }.count
    #expect(readyCount == 2)

    // Verify the daemon also emitted an error event with the capture-stopped message.
    let errorMessages = sink.recordedEvents().compactMap { event -> String? in
      if case .error(_, let data) = event { return data.message }
      return nil
    }
    #expect(errorMessages.contains { $0.contains("Capture stopped unexpectedly") })
  }

  // --- set_mic_enabled ---

  @Test("set_mic_enabled command toggles mic state without a session")
  func setMicEnabledTogglesStateWithoutSession() async throws {
    let micState = MicEnabledState(initiallyEnabled: true)
    _ = try await runDaemon(
      commands: [
        .command(.setMicEnabled(enabled: false)),
        .command(.setMicEnabled(enabled: true)),
        .command(.setMicEnabled(enabled: false)),
      ],
      micEnabledState: micState
    )
    #expect(micState.isEnabled() == false)
  }

  @Test("set_mic_enabled command works mid-session and emits no events")
  func setMicEnabledMidSession() async throws {
    let micState = MicEnabledState(initiallyEnabled: true)
    let sink = try await runDaemon(
      commands: [
        .command(.start),
        .command(.setMicEnabled(enabled: false)),
        .command(.stop),
      ],
      micEnabledState: micState
    )
    #expect(micState.isEnabled() == false)
    // 状態変更は応答イベントを発しない (フロントは楽観的に更新)。
    let kinds = sink.recordedEvents().map { $0.typeString }
    #expect(!kinds.contains("warning"))
    #expect(
      !sink.recordedEvents().contains(where: { event in
        if case .error = event { return true }
        return false
      })
    )
  }

  // --- stdin EOF ---

  @Test("stdin EOF mid-session drains the session cleanly")
  func stdinEOFMidSessionDrains() async throws {
    let sink = try await runDaemon(commands: [
      .command(.start)
      // EOF (no stop) — daemon should drain the active session before exiting.
    ])
    let stopReasons = sink.recordedEvents().compactMap { event -> StopReason? in
      if case .sessionStopped(_, let data) = event { return data.reason }
      return nil
    }
    #expect(stopReasons == [.stop])
  }
}
