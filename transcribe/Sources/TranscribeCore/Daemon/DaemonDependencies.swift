import Foundation

/// `TranscribeDaemon.run` が必要とする外部依存を束ねた DI コンテナ。
/// production では `.default` を使い、テストでは fake を差し替える。
///
/// 設計メモ:
/// - `permissionCheck` は spec §A-2 に従って **start コマンド毎** に呼ばれる
///   (boot 時には呼ばない — 権限後付け→次回 start で reflect させたいので)。
/// - `captureFactory` は **セッション毎に必ず新しい capture を返すこと** (旧
///   `PipelineDependencies` の同名フィールドの不変条件を継承)。memoize すると
///   stop 後に再 start できなくなる。
/// - `eventSink` は daemon ライフタイム全体で同一インスタンスを使う。
/// - `commandSource` は 0 引数 closure。daemon は `run()` で 1 度呼んで
///   `AsyncStream<CommandSourceItem>` を取得し、それを drain する。
public struct DaemonDependencies: Sendable {
  public let permissionCheck: @Sendable () async throws -> Void
  public let transcriberFactory: any TranscriberFactory
  public let captureFactory: @Sendable (Bool) -> any CaptureProtocol
  public let eventSink: any EventSink
  public let commandSource: @Sendable () -> AsyncStream<CommandSourceItem>

  public init(
    permissionCheck: @escaping @Sendable () async throws -> Void,
    transcriberFactory: any TranscriberFactory,
    captureFactory: @escaping @Sendable (Bool) -> any CaptureProtocol,
    eventSink: any EventSink,
    commandSource: @escaping @Sendable () -> AsyncStream<CommandSourceItem>
  ) {
    self.permissionCheck = permissionCheck
    self.transcriberFactory = transcriberFactory
    self.captureFactory = captureFactory
    self.eventSink = eventSink
    self.commandSource = commandSource
  }
}

extension DaemonDependencies {
  /// Production wiring。`TranscribeDaemon.init(dependencies:)` のデフォルトに渡る。
  public static let `default` = DaemonDependencies(
    permissionCheck: { try await PermissionChecker.ensureAll() },
    transcriberFactory: DefaultTranscriberFactory(),
    captureFactory: { verbose in AudioCapture(verbose: verbose) },
    eventSink: StdoutEventWriter(),
    commandSource: { CommandSource().stream() }
  )
}
