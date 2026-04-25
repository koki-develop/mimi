import Foundation

/// `Pipeline` が必要とする外部依存をすべて closure もしくは protocol existential として束ねた
/// DI コンテナ。production では `.default` を使い、テストでは fake を差し替える。
///
/// 設計メモ:
/// - 4 つの closure (`permissionCheck` / `signalWaiter` / `writerFactory` / `captureFactory`) は
///   いずれも 1 回の呼び出しで完結する操作なので closure として持つ。
/// - `transcriberFactory` だけは「announce → load × 2 → wrap」の多段操作で、
///   引数のシグネチャも複雑なため、名前付き protocol として保持する。
/// - `captureFactory` は **`Pipeline.run` 1 回ごとに必ず新しい capture を返すこと**。
///   memoize して同じインスタンスを返すと shutdown 後に再 start できなくなる。
public struct PipelineDependencies: Sendable {
  public let permissionCheck: @Sendable () async throws -> Void
  public let transcriberFactory: any TranscriberFactory
  public let captureFactory: @Sendable (Bool) -> any CaptureProtocol
  public let signalWaiter: @Sendable () async -> Void
  public let writerFactory: @Sendable (URL) throws -> JSONLWriter

  public init(
    permissionCheck: @escaping @Sendable () async throws -> Void,
    transcriberFactory: any TranscriberFactory,
    captureFactory: @escaping @Sendable (Bool) -> any CaptureProtocol,
    signalWaiter: @escaping @Sendable () async -> Void,
    writerFactory: @escaping @Sendable (URL) throws -> JSONLWriter
  ) {
    self.permissionCheck = permissionCheck
    self.transcriberFactory = transcriberFactory
    self.captureFactory = captureFactory
    self.signalWaiter = signalWaiter
    self.writerFactory = writerFactory
  }
}

extension PipelineDependencies {
  /// Production wiring。`Pipeline.init(dependencies:)` のデフォルト引数として渡る。
  public static let `default` = PipelineDependencies(
    permissionCheck: { try await PermissionChecker.ensureAll() },
    transcriberFactory: DefaultTranscriberFactory(),
    captureFactory: { verbose in
      AudioCapture(verbose: verbose)
    },
    signalWaiter: { await SignalHandler.waitForSIGINT() },
    writerFactory: { url in try JSONLWriter(output: url) }
  )
}
