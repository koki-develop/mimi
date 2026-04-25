import Foundation

/// `Pipeline` を 1 セッション動かすための設定束。
///
/// 不変条件:
/// - `output` は file URL であること (HTTP URL 等は不可)
/// - `modelName` は空文字でないこと
public struct PipelineConfiguration: Sendable {
  public let output: URL
  public let modelName: String
  public let verbose: Bool
  public let transcriber: TranscriberConfiguration

  public init(
    output: URL,
    modelName: String,
    verbose: Bool = false,
    transcriber: TranscriberConfiguration = TranscriberConfiguration()
  ) {
    precondition(output.isFileURL, "PipelineConfiguration.output must be a file URL")
    precondition(!modelName.isEmpty, "PipelineConfiguration.modelName must not be empty")
    self.output = output
    self.modelName = modelName
    self.verbose = verbose
    self.transcriber = transcriber
  }
}
