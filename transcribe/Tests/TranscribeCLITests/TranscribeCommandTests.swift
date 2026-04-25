import Foundation
import Testing

@testable import TranscribeCLI

@Suite struct TranscribeCommandTests {
  @Test func parsesRequiredOutput() throws {
    let command = try TranscribeCommand.parse(["--output", "/tmp/x.jsonl"])
    #expect(command.output == "/tmp/x.jsonl")
    #expect(command.model == "openai_whisper-large-v3-v20240930_turbo")
    #expect(command.language == "ja")
    #expect(command.verbose == false)
  }

  @Test func parsesModelOverride() throws {
    let command = try TranscribeCommand.parse(["-o", "/tmp/x.jsonl", "-m", "base"])
    #expect(command.output == "/tmp/x.jsonl")
    #expect(command.model == "base")
  }

  @Test func parsesLanguageFlag() throws {
    let command = try TranscribeCommand.parse(["-o", "/tmp/x.jsonl", "-l", "en"])
    #expect(command.language == "en")
  }

  @Test func parsesVerboseFlag() throws {
    let command = try TranscribeCommand.parse(["-o", "/tmp/x.jsonl", "--verbose"])
    #expect(command.verbose == true)
  }

  @Test func failsWithoutOutput() {
    #expect(throws: (any Error).self) {
      _ = try TranscribeCommand.parse([])
    }
  }

  @Test func commandConfigurationDeclaresExpectedAbstract() {
    #expect(TranscribeCommand.configuration.commandName == "transcribe")
    #expect(
      TranscribeCommand.configuration.abstract
        == "Capture macOS system audio + microphone and transcribe to JSONL in real time.")
    #expect(TranscribeCommand.configuration.version == "0.1.0")
  }
}
