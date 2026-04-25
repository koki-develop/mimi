import ArgumentParser
import Foundation
import TranscribeCore

/// CLI 入口の `AsyncParsableCommand`。
/// library として切り出してあるので、executable target に依存せず unit test できる。
public struct TranscribeCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "transcribe",
    abstract: "Capture macOS system audio + microphone and transcribe to JSONL in real time.",
    version: "0.1.0"
  )

  @Option(name: [.short, .long], help: "Path to write JSONL output.")
  public var output: String

  @Option(name: [.short, .long], help: "WhisperKit model name.")
  public var model: String = "openai_whisper-large-v3-v20240930_turbo"

  @Option(name: [.short, .long], help: "Transcription language (default: ja).")
  public var language: String = "ja"

  @Flag(name: [.short, .long], help: "Print per-window diagnostic info to stderr.")
  public var verbose: Bool = false

  public init() {}

  public mutating func run() async throws {
    let url = URL(fileURLWithPath: output)
    let pipeline = Pipeline(
      configuration: PipelineConfiguration(
        output: url,
        modelName: model,
        verbose: verbose,
        transcriber: TranscriberConfiguration(language: language)
      )
    )

    do {
      try await pipeline.run()
    } catch let pipelineError as PipelineError {
      throw ExitCode(pipelineError.exitCode)
    } catch {
      throw ExitCode(70)  // EX_SOFTWARE
    }
  }
}
