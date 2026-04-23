import Foundation
import Testing
@testable import transcribe

@Suite struct SegmentTests {
    @Test func encodesSegmentWithSpecSchema() throws {
        let segment = Segment(
            source: .mic,
            timestamp: Date(timeIntervalSince1970: 1_745_395_200.123),
            duration: 2.47,
            text: "こんにちは、今日は打ち合わせの時間ですね。"
        )

        let data = try JSONLSerializer.encode(segment)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"type\":\"segment\""))
        #expect(json.contains("\"source\":\"mic\""))
        #expect(json.contains("\"duration\":2.47"))
        #expect(json.contains("\"text\":\"こんにちは、今日は打ち合わせの時間ですね。\""))
        #expect(json.range(of: #"\"timestamp\":\"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}"#, options: .regularExpression) != nil)
    }

    @Test func encodesSystemSource() throws {
        let segment = Segment(source: .system, timestamp: Date(), duration: 1.0, text: "hi")
        let json = String(data: try JSONLSerializer.encode(segment), encoding: .utf8)!
        #expect(json.contains("\"source\":\"system\""))
    }

    @Test func decodesSegmentRoundTrip() throws {
        let original = Segment(
            source: .mic,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.5),
            duration: 1.25,
            text: "x"
        )
        let data = try JSONLSerializer.encode(original)
        let decoded = try JSONLSerializer.decode(Segment.self, from: data)

        #expect(decoded.source == original.source)
        #expect(decoded.text == original.text)
        #expect(decoded.duration == original.duration)
        #expect(abs(decoded.timestamp.timeIntervalSince(original.timestamp)) < 0.002)
    }

    @Test func typeFieldIsAlwaysSegment() throws {
        let segment = Segment(source: .system, timestamp: Date(), duration: 0.5, text: "t")
        let data = try JSONLSerializer.encode(segment)
        let decoded = try JSONLSerializer.decode(Segment.self, from: data)
        #expect(decoded.type == "segment")
    }
}
