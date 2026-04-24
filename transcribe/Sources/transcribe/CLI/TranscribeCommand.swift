import ArgumentParser
import Foundation

@main
struct TranscribeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcribe",
    abstract: "Capture macOS system audio + microphone and transcribe to JSONL in real time.",
    version: "0.1.0"
  )

  @Option(name: [.short, .long], help: "Path to write JSONL output.")
  var output: String

  @Option(name: [.short, .long], help: "WhisperKit model name.")
  var model: String = "openai_whisper-large-v3-v20240930_turbo"

  @Flag(name: [.short, .long], help: "Print per-window diagnostic info to stderr.")
  var verbose: Bool = false

  mutating func run() async throws {
    let url = URL(fileURLWithPath: output)
    do {
      try await App.run(output: url, modelName: model, verbose: verbose)
    } catch {
      throw ExitCode.failure
    }
  }
}
