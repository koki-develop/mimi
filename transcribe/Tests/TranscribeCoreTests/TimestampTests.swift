import Foundation
import Testing

@testable import TranscribeCore

@Suite struct TimestampTests {
  @Test func roundTripWithFractionalSeconds() throws {
    let original = Date(timeIntervalSince1970: 1_700_000_123.456)
    let str = Timestamp.string(from: original)
    let parsed = try #require(Timestamp.date(from: str))
    // ISO8601 ms 精度なので 1ms 以内
    #expect(abs(parsed.timeIntervalSince(original)) < 0.0011)
  }

  @Test func emitsFractionalSeconds() {
    let date = Date(timeIntervalSince1970: 1_700_000_123)
    let str = Timestamp.string(from: date)
    #expect(str.contains("."))
  }

  @Test func returnsNilForInvalidInput() {
    #expect(Timestamp.date(from: "not-a-date") == nil)
  }
}
