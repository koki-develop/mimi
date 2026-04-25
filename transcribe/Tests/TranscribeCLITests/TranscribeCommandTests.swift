import Foundation
import Testing

@testable import TranscribeCLI

@Suite struct TranscribeCommandTests {
  @Test func parsesWithDefaults() throws {
    let command = try TranscribeCommand.parse([])
    #expect(command.model == "openai_whisper-large-v3-v20240930_turbo")
    #expect(command.language == "ja")
    #expect(command.verbose == false)
  }

  @Test func parsesModelOverride() throws {
    let command = try TranscribeCommand.parse(["--model", "base"])
    #expect(command.model == "base")
  }

  @Test func parsesLanguageFlag() throws {
    let command = try TranscribeCommand.parse(["--language", "en"])
    #expect(command.language == "en")
  }

  @Test func parsesVerboseFlag() throws {
    let command = try TranscribeCommand.parse(["--verbose"])
    #expect(command.verbose == true)
  }

  @Test func parsesShortFlags() throws {
    let command = try TranscribeCommand.parse(["-m", "small", "-l", "en", "-v"])
    #expect(command.model == "small")
    #expect(command.language == "en")
    #expect(command.verbose == true)
  }

  @Test func rejectsUnknownOptionOutput() {
    // -o / --output was removed when the CLI became a daemon.
    #expect(throws: (any Error).self) {
      _ = try TranscribeCommand.parse(["--output", "/tmp/x.jsonl"])
    }
  }

  @Test func commandConfigurationDeclaresDaemonAbstract() {
    #expect(TranscribeCommand.configuration.commandName == "transcribe")
    #expect(
      TranscribeCommand.configuration.abstract
        == "Long-lived transcription daemon. Loads WhisperKit at boot, then services start/stop commands on stdin (line-delimited JSON)."
    )
    #expect(TranscribeCommand.configuration.version == "0.2.0")
  }
}
