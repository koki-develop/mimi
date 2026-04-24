import Foundation
@preconcurrency import WhisperKit

public enum AppError: Error, Equatable {
  case outputExists(String)
  case permission(String)
  case model(String)
  case capture(String)
  case io(String)
  case unexpected(String)
}

public struct App {
  public static func run(output: URL, modelName: String, verbose: Bool = false) async throws {
    // 1. JSONLWriter 作成(O_EXCL でアトミックに作成するため既存ファイルは安全に拒否される)
    let writer: JSONLWriter
    do {
      writer = try JSONLWriter(output: output)
    } catch JSONLWriterError.outputAlreadyExists {
      // 既存ファイル時は JSONL に何も書けないので stderr 専用(spec line 144)
      let prelude = ConsoleReporter()
      await prelude.reportError("Output file already exists: \(output.path)")
      throw AppError.outputExists(output.path)
    } catch {
      let prelude = ConsoleReporter()
      await prelude.reportError("I/O error: \(error)")
      throw AppError.io(String(describing: error))
    }

    // 3. EventLogger 構築
    let console = ConsoleReporter()
    let logger = EventLogger(writer: writer, console: console)

    // 4. session_started 発行
    await logger.sessionStarted(model: modelName)

    // JSONL クローズ: 失敗時は stderr に通知する(silent failure を避けるため)。
    func closeWriter() async {
      do {
        try await writer.close()
      } catch {
        await console.reportError("Failed to close JSONL: \(error)")
      }
    }

    // 致命エラー共通後始末
    func fail(_ err: AppError, message: String) async throws -> Never {
      await logger.error(message)
      await logger.sessionStopped(reason: .error)
      await closeWriter()
      throw err
    }

    // 5. パーミッション確認。想定外の error も fail() 経由で JSONL に残すため generic catch を用意する。
    // 将来 PermissionChecker が新しい error を throw しても、`AppError.permission` に
    // 誤分類せず `.unexpected` として隔離する。
    do {
      try await PermissionChecker.ensureAll()
    } catch PermissionError.screenRecordingDenied {
      try await fail(.permission("screen"), message: "Screen Recording permission required.")
    } catch PermissionError.microphoneDenied {
      try await fail(.permission("mic"), message: "Microphone permission required.")
    } catch {
      try await fail(
        .unexpected(String(describing: error)), message: "Permission check failed: \(error)")
    }

    // 6. state_changed: loading_model
    await logger.stateChanged(.loadingModel)

    // 7. モデル読み込み
    let loader = ModelLoader()
    let micModel: LoadedModel
    let systemModel: LoadedModel
    do {
      micModel = try await loader.load(
        name: modelName,
        computeOptions: ModelComputeOptions(
          melCompute: .cpuAndNeuralEngine,
          audioEncoderCompute: .cpuAndNeuralEngine,
          textDecoderCompute: .cpuAndNeuralEngine,
          prefillCompute: .cpuOnly
        ),
        reporter: logger
      )
      systemModel = try await loader.load(
        name: modelName,
        computeOptions: ModelComputeOptions(
          melCompute: .cpuAndGPU,
          audioEncoderCompute: .cpuAndGPU,
          textDecoderCompute: .cpuAndGPU,
          prefillCompute: .cpuOnly
        ),
        reporter: logger
      )
    } catch {
      try await fail(
        .model(String(describing: error)), message: "Failed to load model '\(modelName)': \(error)")
    }

    // 8. キャプチャ開始
    let capture = AudioCapture(reporter: logger, verbose: verbose)
    do {
      try await capture.start()
    } catch {
      try await fail(.capture(String(describing: error)), message: "Capture failed: \(error)")
    }

    // 9. state_changed: capturing
    await logger.stateChanged(.capturing)

    // 10. stderr 人間向けメッセージ
    await logger.statusMessage("Recording started. Press Ctrl+C to stop.")

    // 11. メインループ。
    // 正常停止は SIGINT 経由。それ以外に SCStream の didStopWithError 等で
    // stream が予期せず閉じて consumer が先にドレインされるケースも存在するため、
    // どちらが先に発生したかを StopReasonTracker で記録し、最後の sessionStopped に反映する。
    // consumer 先行終了のときは SIGINT 待機タスクをキャンセルして group を閉じる。
    let micTranscriber = Transcriber(
      source: .mic, model: micModel, reporter: logger, verbose: verbose)
    let systemTranscriber = Transcriber(
      source: .system, model: systemModel, reporter: logger, verbose: verbose)
    let counter = Counter()
    let stopReason = StopReasonTracker()

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await segment in micTranscriber.consume(capture.micStream) {
          await logger.report(segment)
          await counter.increment()
        }
        await stopReason.trySet(.error)
      }
      group.addTask {
        for await segment in systemTranscriber.consume(capture.systemStream) {
          await logger.report(segment)
          await counter.increment()
        }
        await stopReason.trySet(.error)
      }
      group.addTask {
        await SignalHandler.waitForSIGINT()
        // cancelAll で起こされたケース(consumer 先行終了)では
        // stateChanged(.stopping) を発行しない(spec: stopping は SIGINT 経由のみ)
        if Task.isCancelled { return }
        await stopReason.trySet(.sigint)
        await logger.stateChanged(.stopping)
        await capture.stop()
      }

      // 最初に完了したタスクの種類で停止原因を判定する。
      // consumer が先に終わっていたら SIGINT 待機は無用なのでキャンセルする。
      await group.next()
      if await stopReason.resolved != .sigint {
        group.cancelAll()
      }
      for await _ in group {}
    }

    // 12-13. 終了サマリ + JSONL 終端

    // consumer 先行終了(SCStream didStopWithError 経由など)でも
    // SCStream / delegate / OutputHandler を確実に解放するため capture.stop() を呼ぶ。
    // SIGINT 経路では既に呼ばれているので idempotent に動作する。
    await capture.stop()

    // Delegate が記録した予期せぬ stream エラーがあれば、resolvedReason に依らず
    // 常に drain して `error` イベントを emit する。consumer のドレインより先に
    // SIGINT が届いて resolvedReason が .sigint になっても、実際は stream エラーで
    // 停止したケースを取りこぼさないようにする(streamErrorBox.take() は clear-on-read)。
    let streamError = capture.takeStreamError()
    if let streamError {
      await logger.error("Capture stopped unexpectedly: \(streamError)")
    }

    // stream error があった場合は reason も .error に上書きする(SIGINT より
    // stream error を優先)。precedence は resolvedStopReason に切り出して
    // 単体テスト可能にしてある。
    let resolvedReason = App.resolvedStopReason(
      streamErrorPresent: streamError != nil,
      trackerReason: await stopReason.resolved
    )

    let total = await counter.value
    await logger.statusMessage("Stopped. Wrote \(total) segments to \(output.path).")
    await logger.sessionStopped(reason: resolvedReason)
    await closeWriter()
  }

  actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  actor StopReasonTracker {
    private var value: StopReason?
    func trySet(_ reason: StopReason) { if value == nil { value = reason } }
    var resolved: StopReason { value ?? .error }
  }

  /// 最終 session_stopped の reason 決定ロジック。
  /// 予期せぬ stream error が検出されていれば SIGINT より優先して `.error` を返す。
  /// それ以外は StopReasonTracker から解決済みの reason をそのまま返す。
  static func resolvedStopReason(streamErrorPresent: Bool, trackerReason: StopReason) -> StopReason
  {
    if streamErrorPresent { return .error }
    return trackerReason
  }
}
