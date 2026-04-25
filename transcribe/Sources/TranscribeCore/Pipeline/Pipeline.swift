import Foundation

/// 1 セッションのライフサイクルを所有する actor。
/// permission → model load → capture start → consumer task group → shutdown を
/// 直線的にオーケストレートする。
public actor Pipeline {
  private let configuration: PipelineConfiguration
  private let dependencies: PipelineDependencies

  public init(
    configuration: PipelineConfiguration,
    dependencies: PipelineDependencies = .default
  ) {
    self.configuration = configuration
    self.dependencies = dependencies
  }

  public func run() async throws {
    // 1. JSONLWriter 作成 (O_EXCL でアトミック作成)
    let writer: JSONLWriter
    do {
      writer = try dependencies.writerFactory(configuration.output)
    } catch JSONLWriterError.outputAlreadyExists {
      // 既存ファイル時は JSONL に何も書けないので stderr 専用
      let prelude = ConsoleReporter()
      await prelude.reportError("Output file already exists: \(configuration.output.path)")
      throw PipelineError.outputAlreadyExists(path: configuration.output.path)
    } catch {
      let prelude = ConsoleReporter()
      await prelude.reportError("I/O error: \(error)")
      throw PipelineError.ioFailed(reason: String(describing: error))
    }

    let console = ConsoleReporter()
    let logger = EventLogger(writer: writer, console: console)

    // 2. session_started
    await logger.sessionStarted(model: configuration.modelName)

    // closeWriter は失敗時の error も返す。Pipeline.run の最終 throw 判定で使う。
    func closeWriter() async -> Error? {
      do {
        try await writer.close()
        return nil
      } catch {
        await console.reportError("Failed to close JSONL: \(error)")
        return error
      }
    }

    func fail(_ err: PipelineError, message: String) async throws -> Never {
      await logger.error(message)
      await logger.sessionStopped(reason: .error)
      _ = await closeWriter()
      throw err
    }

    // 3. permission
    do {
      try await dependencies.permissionCheck()
    } catch let permissionError as PermissionError {
      // PermissionError の各 case を 1 箇所で扱う。新しい case 追加時は
      // 下の switch がコンパイルエラーになるので silent な変動を防ぐ。
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
      try await fail(.permissionDenied(permissionError), message: message)
    } catch {
      try await fail(
        .unexpected(reason: String(describing: error)),
        message: "Permission check failed: \(error)")
    }

    // 4. state_changed: loading_model
    await logger.stateChanged(.loadingModel)

    // 5. transcribers (model load + announce + Transcriber wrap)
    let micTranscriber: any TranscriberProtocol
    let systemTranscriber: any TranscriberProtocol
    do {
      let pair = try await dependencies.transcriberFactory.makeTranscribers(
        modelName: configuration.modelName,
        configuration: configuration.transcriber,
        verbose: configuration.verbose,
        logger: logger
      )
      micTranscriber = pair.mic
      systemTranscriber = pair.system
    } catch {
      try await fail(
        .modelLoadFailed(reason: String(describing: error)),
        message: "Failed to load model '\(configuration.modelName)': \(error)")
    }

    // 6. capture start
    let capture = dependencies.captureFactory(configuration.verbose)
    do {
      try await capture.start()
    } catch {
      try await fail(
        .captureFailed(reason: String(describing: error)), message: "Capture failed: \(error)")
    }

    // 7. state_changed: capturing
    await logger.stateChanged(.capturing)

    // 8. stderr 人間向けメッセージ
    await logger.statusMessage("Recording started. Press Ctrl+C to stop.")

    // 9. メインループ
    let coordinator = ShutdownCoordinator()

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await segment in micTranscriber.consume(capture.micStream) {
          await logger.report(segment)
          await coordinator.recordSegment()
        }
        await coordinator.recordConsumerEOF()
      }
      group.addTask {
        for await segment in systemTranscriber.consume(capture.systemStream) {
          await logger.report(segment)
          await coordinator.recordSegment()
        }
        await coordinator.recordConsumerEOF()
      }
      group.addTask {
        // diagnostic stream を drain して logger に転送する。
        for await diagnostic in capture.diagnosticStream {
          switch diagnostic {
          case .warning(_, let message):
            await logger.warning(message)
          case .status(let message):
            await logger.statusMessage(message)
          }
        }
      }
      group.addTask {
        await self.dependencies.signalWaiter()
        // cancelAll で起こされたケース(consumer 先行終了)では stateChanged(.stopping) を発行しない。
        if Task.isCancelled { return }
        // recordSIGINT を必ず capture.stop() より先に呼ぶ。
        // capture.stop() が consumer EOF を起こすが、その前に reason = .sigint が tryset 済みになる。
        await coordinator.recordSIGINT()
        await logger.stateChanged(.stopping)
        await capture.stop()
      }

      // 最初に完了したタスクの種類で停止原因を判定。
      // SIGINT 経路 (= recordSIGINT が呼ばれて currentReason が .sigint) でなければ
      // consumer 先行終了とみなし、全タスクをキャンセルする。
      await group.next()
      if await coordinator.currentReason() != .sigint {
        group.cancelAll()
      }
      for await _ in group {}
    }

    // 10. 後処理: capture.stop() (idempotent), stream error 取り出し, finalize, sessionStopped, close
    await capture.stop()

    let streamError = capture.takeStreamError()
    let outcome = await coordinator.finalize(streamError: streamError)

    switch outcome {
    case .sigint:
      break
    case .error(let message, _):
      if let message {
        await logger.error(message)
      }
    }

    await logger.statusMessage(
      "Stopped. Wrote \(outcome.segmentCount) segments to \(configuration.output.path).")
    await logger.sessionStopped(reason: outcome.reason)
    let closeError = await closeWriter()

    // 11. 終了時 throw 判定。優先順位は: stream error > JSONL write 失敗 > writer close 失敗。
    //   - stream error: capture が予期せず停止した。captureFailed を throw して exit code 74。
    //   - JSONL write 失敗: 全イベントが書けてない可能性。ioFailed を throw して exit code 74。
    //   - writer close 失敗: synchronize/close で I/O エラー。ioFailed を throw して exit code 74。
    // どれも CLI からは "I/O 系で異常終了" として観測されるが、stream error は capture 由来なので
    // captureFailed の category を残す。
    if let streamError {
      throw PipelineError.captureFailed(reason: String(describing: streamError))
    }
    if await logger.flushedWithErrors() {
      throw PipelineError.ioFailed(reason: "JSONL write failed during session")
    }
    if let closeError {
      throw PipelineError.ioFailed(reason: "Failed to close JSONL: \(closeError)")
    }
  }
}
