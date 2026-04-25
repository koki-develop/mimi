import Foundation
@preconcurrency import WhisperKit

/// Daemon の boot 時 1 度だけ呼ばれる `loadModels` と、各セッション開始時に呼ばれる
/// `makeTranscribers` の 2 段構成。`LoadedModels` を boot 時に作って使い回す。
/// テストでは `FakeTranscriberFactory` / `PreloadedTranscriberFactory` を差し替える。
public protocol TranscriberFactory: Sendable {
  /// boot 時に 1 度だけ呼ばれる。WhisperKit インスタンスを 2 つ
  /// (mic = ANE / system = GPU) ロードする。
  func loadModels(modelName: String, logger: EventLogger) async throws -> LoadedModels

  /// 各セッション開始時に呼ばれる。`loadModels` が返した `LoadedModels` を
  /// 流用して、セッション専用の状態 (windowIndex, lastEmittedText, EnergyVAD) を
  /// 持つ fresh な `Transcriber` を 2 つ build する。
  func makeTranscribers(
    models: LoadedModels,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) -> (mic: any TranscriberProtocol, system: any TranscriberProtocol)
}

/// production 実装。`loadModels` で `ModelLoader.load` を 2 回呼んで `LoadedModels` を返し、
/// `makeTranscribers` で fresh な `Transcriber` を 2 つ build する。
public struct DefaultTranscriberFactory: TranscriberFactory {
  public init() {}

  public func loadModels(modelName: String, logger: EventLogger) async throws -> LoadedModels {
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
    return LoadedModels(mic: micModel, system: systemModel)
  }

  public func makeTranscribers(
    models: LoadedModels,
    configuration: TranscriberConfiguration,
    verbose: Bool,
    logger: EventLogger
  ) -> (mic: any TranscriberProtocol, system: any TranscriberProtocol) {
    let micTranscriber = Transcriber(
      source: .mic,
      model: models.mic,
      reporter: logger,
      configuration: configuration,
      verbose: verbose
    )
    let systemTranscriber = Transcriber(
      source: .system,
      model: models.system,
      reporter: logger,
      configuration: configuration,
      verbose: verbose
    )
    return (mic: micTranscriber, system: systemTranscriber)
  }
}

/// WhisperKit でロード済みのモデル。
/// `TranscriberFactory` 実装内部の中間型。library API 境界には露出しない。
///
/// 不変条件:
/// - production 経路 (`DefaultTranscriberFactory.loadModels`) では `kit` は常に非 nil。
/// - テスト経路 (`PreloadedTranscriberFactory` 等) では `kit` は nil — fake transcribers と
///   組み合わせて使うため `Transcriber.init` には到達しない (precondition で fail-fast)。
///
/// 注: `@unchecked Sendable` は WhisperKit が `@preconcurrency` import なのが理由。
/// 並行アクセスは `Transcriber` actor に閉じ込めている。
struct LoadedModel: @unchecked Sendable {
  let name: String
  let kit: WhisperKit?
}

/// Daemon の boot 時に 1 度だけロードされる、mic + system 両 source 用の
/// `LoadedModel` ペア。`TranscribeDaemon` がライフタイムを所有する。
public struct LoadedModels: @unchecked Sendable {
  let mic: LoadedModel
  let system: LoadedModel

  /// テスト用 placeholder。`PreloadedTranscriberFactory.makeTranscribers` が
  /// 中身を参照せず fake transcribers を返す前提でのみ使う。
  public static let testingPlaceholder = LoadedModels(
    mic: LoadedModel(name: "test-mic", kit: nil),
    system: LoadedModel(name: "test-system", kit: nil)
  )
}
