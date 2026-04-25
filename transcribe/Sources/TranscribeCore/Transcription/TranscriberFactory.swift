import Foundation
@preconcurrency import WhisperKit

/// `Pipeline` に対して mic + system 両 source 分の transcribers を返す factory。
/// production 実装は内部で:
///   1. `logger.statusMessage("Loading model (\(name))...")` を一度だけ
///   2. `ModelLoader.load` × 2 (mic = ANE / system = GPU、ANE 競合回避)
///   3. `logger.statusMessage("Ready.")` を一度だけ
///   4. `Transcriber` を 2 つ build して return
/// テストでは `FakeTranscriberFactory` 等を差し替える。
public protocol TranscriberFactory: Sendable {
  func makeTranscribers(
    modelName: String,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) async throws -> (mic: any TranscriberProtocol, system: any TranscriberProtocol)
}

/// production 実装。`ModelLoader.load` を 2 回呼んで `Transcriber` を 2 つ build。
public struct DefaultTranscriberFactory: TranscriberFactory {
  public init() {}

  public func makeTranscribers(
    modelName: String,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) async throws -> (mic: any TranscriberProtocol, system: any TranscriberProtocol) {
    await logger.statusMessage("Loading model (\(modelName))...")

    let micModel = try await ModelLoader.load(
      name: modelName,
      computeOptions: ModelComputeOptions(
        melCompute: .cpuAndNeuralEngine,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine,
        prefillCompute: .cpuOnly
      )
    )
    let systemModel = try await ModelLoader.load(
      name: modelName,
      computeOptions: ModelComputeOptions(
        melCompute: .cpuAndGPU,
        audioEncoderCompute: .cpuAndGPU,
        textDecoderCompute: .cpuAndGPU,
        prefillCompute: .cpuOnly
      )
    )

    await logger.statusMessage("Ready.")

    let micTranscriber = Transcriber(
      source: .mic,
      model: micModel,
      reporter: logger,
      configuration: configuration,
      verbose: verbose
    )
    let systemTranscriber = Transcriber(
      source: .system,
      model: systemModel,
      reporter: logger,
      configuration: configuration,
      verbose: verbose
    )
    return (mic: micTranscriber, system: systemTranscriber)
  }
}

/// WhisperKit でロード済みのモデル。
/// `TranscriberFactory` 実装内部の中間型。library API 境界には露出しない。
/// 注: `@unchecked Sendable` は WhisperKit が `@preconcurrency` import なのが理由。
/// 並行アクセスは `Transcriber` actor に閉じ込めている。
struct LoadedModel: @unchecked Sendable {
  let name: String
  let kit: WhisperKit
}
