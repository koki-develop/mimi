import Foundation
import Testing

@testable import transcribe

@Suite struct TranscribeCommandTests {
  @Test func parsesRequiredOutput() throws {
    let command = try TranscribeCommand.parse(["--output", "/tmp/x.jsonl"])
    #expect(command.output == "/tmp/x.jsonl")
    #expect(command.model == "openai_whisper-large-v3-v20240930_turbo")
    #expect(command.verbose == false)
  }

  @Test func parsesModelOverride() throws {
    let command = try TranscribeCommand.parse(["-o", "/tmp/x.jsonl", "-m", "base"])
    #expect(command.output == "/tmp/x.jsonl")
    #expect(command.model == "base")
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
}
