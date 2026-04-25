import Foundation
import Testing

@testable import TranscribeCore

@Suite struct EventTests {
  private func encode(_ event: Event) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let data = try encoder.encode(event)
    return String(data: data, encoding: .utf8)!
  }

  @Test func eventExposesTypeString() {
    let ts = Date(timeIntervalSince1970: 0)
    let event = Event.sessionStarted(
      timestamp: ts,
      data: SessionStartedData(model: "whisper-small")
    )
    #expect(event.typeString == "session_started")
    #expect(event.timestamp == ts)
  }

  @Test func encodesSessionStarted() throws {
    let ts = Date(timeIntervalSince1970: 1_700_000_000)
    let event = Event.sessionStarted(
      timestamp: ts,
      data: SessionStartedData(model: "whisper-small")
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"session_started\""))
    #expect(json.contains("\"data\":{\"model\":\"whisper-small\"}"))
    // ISO8601 fractional seconds + TZ を pin する。
    // タイムゾーンは local だが UTC 環境では `Z` で表現される場合もあるため両方許容。
    let tsRegex =
      #"\"timestamp\":\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(Z|[+-]\d{2}:\d{2})\""#
    #expect(json.range(of: tsRegex, options: .regularExpression) != nil)
  }

  @Test func encodesStateChangedLoadingModel() throws {
    let event = Event.stateChanged(
      timestamp: Date(timeIntervalSince1970: 0),
      data: StateChangedData(state: .loadingModel)
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"state_changed\""))
    #expect(json.contains("\"data\":{\"state\":\"loading_model\"}"))
  }

  @Test func encodesStateChangedCapturing() throws {
    let event = Event.stateChanged(
      timestamp: Date(timeIntervalSince1970: 0),
      data: StateChangedData(state: .capturing)
    )
    let json = try encode(event)
    #expect(json.contains("\"data\":{\"state\":\"capturing\"}"))
  }

  @Test func encodesStateChangedStopping() throws {
    let event = Event.stateChanged(
      timestamp: Date(timeIntervalSince1970: 0),
      data: StateChangedData(state: .stopping)
    )
    let json = try encode(event)
    #expect(json.contains("\"data\":{\"state\":\"stopping\"}"))
  }

  @Test func encodesSegment() throws {
    let event = Event.segment(
      timestamp: Date(timeIntervalSince1970: 0),
      data: SegmentData(source: .mic, duration: 1.2, text: "hi")
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"segment\""))
    #expect(json.contains("\"source\":\"mic\""))
    #expect(json.contains("\"duration\":1.2"))
    #expect(json.contains("\"text\":\"hi\""))
  }

  @Test func encodesWarning() throws {
    let event = Event.warning(
      timestamp: Date(timeIntervalSince1970: 0),
      data: WarningData(message: "slow")
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"warning\""))
    #expect(json.contains("\"data\":{\"message\":\"slow\"}"))
  }

  @Test func encodesError() throws {
    let event = Event.error(
      timestamp: Date(timeIntervalSince1970: 0),
      data: ErrorData(message: "boom")
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"error\""))
    #expect(json.contains("\"data\":{\"message\":\"boom\"}"))
  }

  @Test func encodesSessionStoppedSigint() throws {
    let event = Event.sessionStopped(
      timestamp: Date(timeIntervalSince1970: 0),
      data: SessionStoppedData(reason: .sigint)
    )
    let json = try encode(event)
    #expect(json.contains("\"type\":\"session_stopped\""))
    #expect(json.contains("\"data\":{\"reason\":\"sigint\"}"))
  }

  @Test func encodesSessionStoppedError() throws {
    let event = Event.sessionStopped(
      timestamp: Date(timeIntervalSince1970: 0),
      data: SessionStoppedData(reason: .error)
    )
    let json = try encode(event)
    #expect(json.contains("\"data\":{\"reason\":\"error\"}"))
  }

  @Test func roundTripAllVariants() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let ts = Date(timeIntervalSince1970: 1_700_000_000)

    let events: [Event] = [
      .sessionStarted(timestamp: ts, data: SessionStartedData(model: "m")),
      .stateChanged(timestamp: ts, data: StateChangedData(state: .loadingModel)),
      .stateChanged(timestamp: ts, data: StateChangedData(state: .capturing)),
      .stateChanged(timestamp: ts, data: StateChangedData(state: .stopping)),
      .segment(timestamp: ts, data: SegmentData(source: .system, duration: 2.5, text: "hello")),
      .warning(timestamp: ts, data: WarningData(message: "w")),
      .error(timestamp: ts, data: ErrorData(message: "e")),
      .sessionStopped(timestamp: ts, data: SessionStoppedData(reason: .sigint)),
      .sessionStopped(timestamp: ts, data: SessionStoppedData(reason: .error)),
    ]

    for event in events {
      let data = try encoder.encode(event)
      let decoded = try decoder.decode(Event.self, from: data)
      #expect(decoded == event, "round-trip failed for \(event.typeString)")
    }
  }

  @Test func decodeFailsOnUnknownType() throws {
    let json = #"{"type":"nonsense","timestamp":"2024-01-01T00:00:00.000+00:00","data":{}}"#
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(Event.self, from: json.data(using: .utf8)!)
    }
  }

  @Test func decodeFailsOnMalformedTimestamp() throws {
    // 不完全な ISO8601 / 意味不明文字列 → DecodingError
    let json = #"{"type":"session_started","timestamp":"not-a-date","data":{"model":"m"}}"#
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(Event.self, from: json.data(using: .utf8)!)
    }
  }

  @Test func timestampUsesLocalTimeZoneOffset() throws {
    // ISO8601 + fractional seconds + local TZ contract を pin する。
    // ハードコードされた UTC (`Z`) に regression すると CI (UTC) では通るが
    // 非 UTC の開発機で offset が一致しなくなる。TimeZone.current.secondsFromGMT(for:)
    // と照合して動的に pin する。
    let ts = Date(timeIntervalSince1970: 1_700_000_000)
    let event = Event.sessionStarted(
      timestamp: ts,
      data: SessionStartedData(model: "m")
    )
    let json = try encode(event)
    let expectedOffsetSeconds = TimeZone.current.secondsFromGMT(for: ts)

    if expectedOffsetSeconds == 0 {
      // UTC: ISO8601DateFormatter は `Z` を使い得る(環境による)。どちらでも受容。
      let utcOK = json.contains("+00:00") || json.contains("-00:00") || json.contains("Z\"")
      #expect(utcOK, "expected UTC marker (Z or ±00:00) in timestamp: \(json)")
    } else {
      // 非 UTC: 符号と HH:MM を動的に組み立てて含まれることを確認
      let sign = expectedOffsetSeconds > 0 ? "+" : "-"
      let abs = Swift.abs(expectedOffsetSeconds)
      let hh = String(format: "%02d", abs / 3600)
      let mm = String(format: "%02d", (abs % 3600) / 60)
      let expected = "\(sign)\(hh):\(mm)"
      #expect(json.contains(expected), "expected local offset \(expected) in timestamp: \(json)")
    }
  }
}
