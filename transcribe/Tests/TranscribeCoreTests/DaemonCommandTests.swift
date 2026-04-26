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

  @Test("decodes set_mic_enabled command (true)")
  func decodesSetMicEnabledTrue() throws {
    let json = #"{"type":"set_mic_enabled","enabled":true}"#.data(using: .utf8)!
    let cmd = try JSONDecoder().decode(DaemonCommand.self, from: json)
    #expect(cmd == .setMicEnabled(enabled: true))
  }

  @Test("decodes set_mic_enabled command (false)")
  func decodesSetMicEnabledFalse() throws {
    let json = #"{"type":"set_mic_enabled","enabled":false}"#.data(using: .utf8)!
    let cmd = try JSONDecoder().decode(DaemonCommand.self, from: json)
    #expect(cmd == .setMicEnabled(enabled: false))
  }

  @Test("rejects set_mic_enabled missing enabled field")
  func rejectsSetMicEnabledMissingEnabled() {
    let json = #"{"type":"set_mic_enabled"}"#.data(using: .utf8)!
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(DaemonCommand.self, from: json)
    }
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
