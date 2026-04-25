import ArgumentParser
import Foundation
import TranscribeCore

/// CLI 入口の `AsyncParsableCommand`。
/// library として切り出してあるので、executable target に依存せず unit test できる。
public struct TranscribeCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "transcribe",
    abstract:
      "Long-lived transcription daemon. Loads WhisperKit at boot, then services start/stop commands on stdin (line-delimited JSON).",
    version: "0.2.0"
  )

  @Option(name: [.short, .long], help: "WhisperKit model name.")
  public var model: String = "openai_whisper-large-v3-v20240930_turbo"

  @Option(name: [.short, .long], help: "Transcription language (default: ja).")
  public var language: String = "ja"

  @Flag(name: [.short, .long], help: "Print per-window diagnostic info to stderr.")
  public var verbose: Bool = false

  public init() {}

  public mutating func run() async throws {
    let daemon = TranscribeDaemon(
      configuration: DaemonConfiguration(
        modelName: model,
        verbose: verbose,
        transcriber: TranscriberConfiguration(language: language)
      )
    )
    do {
      try await daemon.run()
    } catch let daemonError as DaemonError {
      throw ExitCode(daemonError.exitCode)
    } catch {
      throw ExitCode(70)  // EX_SOFTWARE
    }
  }
}
