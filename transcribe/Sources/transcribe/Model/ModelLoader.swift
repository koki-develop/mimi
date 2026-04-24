import Foundation
@preconcurrency import WhisperKit

public enum ModelLoaderError: Error {
  case loadFailed(String)
}

public struct LoadedModel: @unchecked Sendable {
  public let name: String
  public let kit: WhisperKit
}

public actor ModelLoader {
  private var announced: Bool = false

  public init() {}

  public func load(
    name: String,
    computeOptions: ModelComputeOptions,
    reporter: EventLogger
  ) async throws -> LoadedModel {
    let shouldAnnounce = !announced
    announced = true

    if shouldAnnounce {
      await reporter.statusMessage("Loading model (\(name))...")
    }
    do {
      let config = WhisperKitConfig(
        model: name,
        computeOptions: computeOptions,
        verbose: false,
        logLevel: .none,
        download: true
      )
      let kit = try await WhisperKit(config)
      if shouldAnnounce {
        await reporter.statusMessage("Ready.")
      }
      return LoadedModel(name: name, kit: kit)
    } catch {
      throw ModelLoaderError.loadFailed(String(describing: error))
    }
  }
}
