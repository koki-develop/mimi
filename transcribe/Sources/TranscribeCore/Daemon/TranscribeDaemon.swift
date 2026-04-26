import Darwin
import Foundation

/// SIGPIPE を SIG_IGN にする。spec §5.4: Tauri host が stdout pipe を
/// abrupt に閉じたとき、SIGPIPE で daemon が即死しないようにする
/// (失敗は EPIPE として StdoutEventWriter.write から throw される)。
private func ignoreSIGPIPE() {
  signal(SIGPIPE, SIG_IGN)
}

public actor TranscribeDaemon {
  private let configuration: DaemonConfiguration
  private let dependencies: DaemonDependencies
  /// daemon ライフタイム全体で 1 インスタンス。`set_mic_enabled` で更新され、
  /// `captureFactory` 経由で各セッションの mic `AudioOutputTap` に共有参照が渡る。
  /// session 跨ぎで保持 (再起動でリセット)。
  private let micEnabledState: MicEnabledState

  public init(
    configuration: DaemonConfiguration,
    dependencies: DaemonDependencies = .default,
    micEnabledState: MicEnabledState = MicEnabledState()
  ) {
    self.configuration = configuration
    self.dependencies = dependencies
    self.micEnabledState = micEnabledState
  }

  /// Daemon の entry point。boot → command loop → stdin EOF で復帰。
  ///
  /// - 単一エントリ前提: プロセス全体で 1 回だけ呼ぶ。actor isolation のため、
  ///   `run()` 実行中に他の actor-isolated メソッドを呼ぶと `await` がぶら下がる。
  ///   `TranscribeDaemon` には `run()` 以外の public method は無いので問題ないが、
  ///   将来追加するときは「stdin EOF で `run()` が return した後でないと呼ばない」
  ///   不変条件を維持すること。
  public func run() async throws {
    ignoreSIGPIPE()

    let logger = EventLogger(sink: dependencies.eventSink, console: ConsoleReporter())

    // 1. loading_model
    await logger.stateChanged(.loadingModel)

    // 2. model load (boot 時 1 度だけ)
    let models: LoadedModels
    do {
      models = try await dependencies.transcriberFactory.loadModels(
        modelName: configuration.modelName,
        logger: logger
      )
    } catch {
      // fatal: model load 失敗。fatal イベント → exit non-zero。
      await logger.stateChanged(.fatal)
      await logger.error("Failed to load model '\(configuration.modelName)': \(error)")
      try? await dependencies.eventSink.close()
      throw DaemonError.modelLoadFailed(reason: String(describing: error))
    }

    // 3. ready
    await logger.stateChanged(.ready)

    // 4. command loop with multiplexed event stream.
    //    The command loop must react to BOTH:
    //      - user commands from stdin (CommandSource)
    //      - session-self-completion (runSession finishing on its own when capture
    //        errors mid-session, without a `stop` command). Without this multiplex,
    //        sessionState would stay Some after a self-completed session and the
    //        next `start` would be rejected as "already recording" even though the
    //        wire protocol already emitted `state_changed { ready }`.
    let (internalStream, internalContinuation) =
      AsyncStream.makeStream(of: DaemonLoopEvent.self)

    Task { [continuation = internalContinuation] in
      for await item in dependencies.commandSource() {
        continuation.yield(.command(item))
      }
      continuation.finish()  // stdin EOF closes the loop
    }

    var sessionHandle: SessionHandle? = nil
    var sessionTask: Task<Void, Never>? = nil

    for await event in internalStream {
      switch event {
      case .command(.parseError(let raw)):
        await logger.error("unknown command: \(raw)")
      case .command(.command(.setMicEnabled(enabled: let enabled))):
        // session の有無に関わらず受理。mic AudioOutputTap が次回 callback で
        // 新しい値を読む。応答イベントは emit しない (フロント側で楽観的に state 更新)。
        micEnabledState.setEnabled(enabled)
      case .command(.command(.start)):
        if sessionHandle != nil {
          await logger.error("already recording")
          continue
        }
        do {
          let handle = try await beginSession(models: models, logger: logger)
          sessionHandle = handle
          let cont = internalContinuation
          sessionTask = Task {
            await self.runSession(session: handle, logger: logger)
            cont.yield(.sessionEnded)
          }
        } catch {
          // beginSession emitted an `error` event; state stays in `ready`
          // (§4 ready→ready edge). No session_started was emitted, so no
          // sessionHandle to set up.
        }
      case .command(.command(.stop)):
        guard let handle = sessionHandle, let task = sessionTask else {
          await logger.error("not recording")
          continue
        }
        await endSession(session: handle, logger: logger)
        _ = await task.value
        sessionHandle = nil
        sessionTask = nil
      // Note: the task body will also yield .sessionEnded after runSession
      // returns; the loop processes that next iteration as a no-op (handle
      // is already nil).
      case .sessionEnded:
        // Session completed by itself (capture error mid-session) OR completed
        // after a stop (in which case the handle/task were nilled already).
        // Either way: ensure both are nil.
        sessionHandle = nil
        sessionTask = nil
      }
    }

    // 5. stdin EOF: drain any in-progress session cleanly.
    //    cmdForwarder Task は for-await が自然終了 (= stdin EOF) で抜けて
    //    continuation.finish() を呼ぶので、明示的な cancel は不要。
    if let handle = sessionHandle, let task = sessionTask {
      await endSession(session: handle, logger: logger)
      _ = await task.value
    }
    try? await dependencies.eventSink.close()
  }
}

extension TranscribeDaemon {
  /// `start` コマンド処理。permission → capture start → transcribers build → state_changed:capturing。
  /// permission 失敗 / capture 失敗時は logger.error と DaemonError を throw、state は ready のまま。
  fileprivate func beginSession(
    models: LoadedModels,
    logger: EventLogger
  ) async throws -> SessionHandle {
    // permission (per-start, A-2)
    do {
      try await dependencies.permissionCheck()
    } catch let permissionError as PermissionError {
      let message: String
      switch permissionError {
      case .screenRecordingDenied:
        message = "Screen Recording permission required."
      case .microphoneDenied:
        message = "Microphone access denied."
      case .microphoneRestricted:
        message = "Microphone access is restricted."
      case .microphoneStatusUnknown(let raw):
        message = "Microphone authorization status unknown (rawValue=\(raw))."
      }
      await logger.error(message)
      throw DaemonError.permissionDenied(permissionError)
    } catch {
      await logger.error("Permission check failed: \(error)")
      throw DaemonError.unexpected(reason: String(describing: error))
    }

    // capture (fresh per session — captureFactory invariant)。daemon-wide な
    // micEnabledState を渡し、capture/mic tap がそれを共有参照する。
    let capture = dependencies.captureFactory(configuration.verbose, micEnabledState)
    do {
      try await capture.start()
    } catch {
      await logger.error("Capture failed: \(error)")
      throw DaemonError.captureFailed(reason: String(describing: error))
    }

    // transcribers (fresh per session — Transcriber holds windowIndex / lastEmittedText state)
    let pair = dependencies.transcriberFactory.makeTranscribers(
      models: models,
      configuration: configuration.transcriber,
      verbose: configuration.verbose,
      logger: logger
    )

    // session_started + state_changed: capturing
    await logger.sessionStarted(model: configuration.modelName)
    await logger.stateChanged(.capturing)
    await logger.statusMessage("Recording started.")

    return SessionHandle(
      capture: capture,
      micTranscriber: pair.mic,
      systemTranscriber: pair.system,
      coordinator: ShutdownCoordinator()
    )
  }

  /// 1 セッションのメインループ。Pipeline.run の旧 step 9-11 相当。
  /// stop コマンド (= endSession 呼び出し) で capture が finish する経路と、
  /// consumer (transcriber / capture stream error) が予期せず先に終わる経路の両方を扱う。
  fileprivate func runSession(session: SessionHandle, logger: EventLogger) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await segment in session.micTranscriber.consume(session.capture.micStream) {
          await logger.report(segment)
          await session.coordinator.recordSegment()
        }
        await session.coordinator.recordConsumerEOF()
      }
      group.addTask {
        for await segment in session.systemTranscriber.consume(session.capture.systemStream) {
          await logger.report(segment)
          await session.coordinator.recordSegment()
        }
        await session.coordinator.recordConsumerEOF()
      }
      group.addTask {
        for await diagnostic in session.capture.diagnosticStream {
          switch diagnostic {
          case .warning(_, let message):
            await logger.warning(message)
          case .status(let message):
            await logger.statusMessage(message)
          }
        }
      }

      // 旧 Pipeline.run と同じく、最初に終わった task の reason を見て後続の扱いを決める。
      // - reason == .stop  → endSession 経由の正常停止。残りの task が capture.stop で
      //                      自然に EOF するのを待つ (cancelAll しない)。
      // - reason != .stop  → consumer / diagnostic が予期せず終了した。残りを cancel して
      //                      stuck を防ぐ (transcriber crash 等のケースをこのパスで吸収)。
      await group.next()
      if await session.coordinator.currentReason() != .stop {
        group.cancelAll()
      }
      for await _ in group {}
    }

    // post-loop finalize
    await session.capture.stop()
    let streamError = session.capture.takeStreamError()
    let outcome = await session.coordinator.finalize(streamError: streamError)

    switch outcome {
    case .stop:
      break
    case .error(let message, _):
      if let message {
        await logger.error(message)
      }
    }

    await logger.statusMessage("Stopped. Wrote \(outcome.segmentCount) segments.")
    await logger.sessionStopped(reason: outcome.reason)
    await logger.stateChanged(.ready)
  }

  /// `stop` コマンド処理。state_changed:stopping → coordinator に stop 記録 → capture.stop()。
  /// 残りの cleanup は runSession の `withTaskGroup` 終了後に走る。
  fileprivate func endSession(session: SessionHandle, logger: EventLogger) async {
    await logger.stateChanged(.stopping)
    await session.coordinator.recordStop()
    await session.capture.stop()
  }
}

/// Per-session state owned by TranscribeDaemon.run during one capturing session.
private struct SessionHandle: Sendable {
  let capture: any CaptureProtocol
  let micTranscriber: any TranscriberProtocol
  let systemTranscriber: any TranscriberProtocol
  let coordinator: ShutdownCoordinator
}

/// Internal event multiplexer for the daemon command loop. Combines user-driven
/// commands (from stdin) with daemon-internal session-completion signals so that
/// a self-completed session (capture error) updates the loop's bookkeeping
/// without waiting for the next user command.
private enum DaemonLoopEvent: Sendable {
  case command(CommandSourceItem)
  case sessionEnded
}
