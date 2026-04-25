import Foundation
import Testing

@testable import TranscribeCore

@Suite("StdoutEventWriter")
struct StdoutEventWriterTests {
  @Test("writes JSON-encoded event followed by newline to the underlying handle")
  func writesEventAsJSONLine() async throws {
    let pipe = Pipe()
    let writer = StdoutEventWriter(handle: pipe.fileHandleForWriting)

    let event = Event.sessionStarted(
      timestamp: Date(timeIntervalSince1970: 0),
      data: SessionStartedData(model: "test-model")
    )
    try await writer.write(event)
    try await writer.close()
    try pipe.fileHandleForWriting.close()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: data, encoding: .utf8) ?? ""
    #expect(s.hasSuffix("\n"))
    #expect(s.contains("\"type\":\"session_started\""))
    #expect(s.contains("\"model\":\"test-model\""))
  }

  @Test("close() makes subsequent writes throw")
  func writeAfterCloseThrows() async throws {
    let pipe = Pipe()
    let writer = StdoutEventWriter(handle: pipe.fileHandleForWriting)
    try await writer.close()

    let event = Event.warning(timestamp: Date(), data: WarningData(message: "x"))
    await #expect(throws: StdoutEventWriterError.closed) {
      try await writer.write(event)
    }
  }
}
