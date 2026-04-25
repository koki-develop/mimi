import Foundation
@preconcurrency import WhisperKit

enum ModelLoaderError: Error, Equatable {
  case loadFailed(String)
}

/// WhisperKit のモデルを 1 度ロードする薄いラッパ。
/// "Loading.../Ready." アナウンスは呼び出し側 (`DefaultTranscriberFactory`) の責任。
/// 注: API は internal — `LoadedModel` も internal なので library 境界に露出しない。
enum ModelLoader {
  static func load(
    name: String,
    computeOptions: ModelComputeOptions
  ) async throws -> LoadedModel {
    do {
      let config = WhisperKitConfig(
        model: name,
        computeOptions: computeOptions,
        verbose: false,
        logLevel: .none,
        download: true
      )
      let kit = try await WhisperKit(config)
      return LoadedModel(name: name, kit: kit)
    } catch {
      throw ModelLoaderError.loadFailed(String(describing: error))
    }
  }
}
