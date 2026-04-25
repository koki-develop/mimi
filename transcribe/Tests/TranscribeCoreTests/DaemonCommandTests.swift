import Foundation
import Testing

@testable import TranscribeCore

@Suite("DaemonCommand")
struct DaemonCommandTests {
  @Test("decodes start command")
  func decodesStart() throws {
    let json = #"{"type":"start"}"#.data(using: .utf8)!
    let cmd = try JSONDecoder().decode(DaemonCommand.self, from: json)
    #expect(cmd == .start)
  }

  @Test("decodes stop command")
  func decodesStop() throws {
    let json = #"{"type":"stop"}"#.data(using: .utf8)!
    let cmd = try JSONDecoder().decode(DaemonCommand.self, from: json)
    #expect(cmd == .stop)
  }

  @Test("rejects unknown type")
  func rejectsUnknownType() {
    let json = #"{"type":"frobnicate"}"#.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(DaemonCommand.self, from: json)
    }
  }

  @Test("rejects missing type")
  func rejectsMissingType() {
    let json = #"{}"#.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(DaemonCommand.self, from: json)
    }
  }
}
