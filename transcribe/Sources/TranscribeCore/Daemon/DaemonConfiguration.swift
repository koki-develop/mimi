import Foundation

/// Daemon を boot するために必要な設定束。
/// `PipelineConfiguration` から `output: URL` を取り除いたもの — daemon は
/// stdout に書くので per-session ファイルパスは存在しない。
///
/// 不変条件:
/// - `modelName` は空文字でないこと
public struct DaemonConfiguration: Sendable {
  public let modelName: String
  public let verbose: Bool
  public let transcriber: TranscriberConfiguration

  public init(
    modelName: String,
    verbose: Bool = false,
    transcriber: TranscriberConfiguration = TranscriberConfiguration()
  ) {
    precondition(!modelName.isEmpty, "DaemonConfiguration.modelName must not be empty")
    self.modelName = modelName
    self.verbose = verbose
    self.transcriber = transcriber
  }
}
