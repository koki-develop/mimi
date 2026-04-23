import Foundation
import Testing
@testable import transcribe

@Suite struct JSONLWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-test-\(UUID().uuidString).jsonl")
    }

    @Test func writesHeaderThenSegments() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let header = Header(startedAt: Date(timeIntervalSince1970: 1_700_000_000), model: "large-v3-turbo")
        let writer = try JSONLWriter(output: url, header: header)

        let seg1 = Segment(source: .mic, timestamp: Date(timeIntervalSince1970: 1_700_000_001), duration: 1.0, text: "hello")
        let seg2 = Segment(source: .system, timestamp: Date(timeIntervalSince1970: 1_700_000_002), duration: 1.5, text: "world")
        try await writer.write(seg1)
        try await writer.write(seg2)
        try await writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4)
        #expect(lines[0].contains("\"type\":\"header\""))
        #expect(lines[0].contains("\"model\":\"large-v3-turbo\""))
        #expect(lines[0].contains("\"started_at\":"))
        #expect(lines[1].contains("\"type\":\"segment\""))
        #expect(lines[1].contains("\"text\":\"hello\""))
        #expect(lines[2].contains("\"text\":\"world\""))
        #expect(lines[3] == "")
    }

    @Test func throwsWhenOutputAlreadyExists() throws {
        let url = tempURL()
        try "existing".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let header = Header(startedAt: Date(), model: "m")

        #expect(throws: JSONLWriterError.self) {
            _ = try JSONLWriter(output: url, header: header)
        }
    }

    @Test func writesPreserveInsertionOrder() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let header = Header(startedAt: Date(), model: "m")
        let writer = try JSONLWriter(output: url, header: header)

        for i in 0..<20 {
            let seg = Segment(source: .mic, timestamp: Date(), duration: 0.1, text: "msg-\(i)")
            try await writer.write(seg)
        }
        try await writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        var cursor = content.startIndex
        for i in 0..<20 {
            guard let range = content.range(of: "msg-\(i)", range: cursor..<content.endIndex) else {
                Issue.record("expected msg-\(i) to appear after msg-\(i - 1)")
                return
            }
            cursor = range.upperBound
        }
    }

    @Test func writeAfterCloseThrows() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let header = Header(startedAt: Date(), model: "m")
        let writer = try JSONLWriter(output: url, header: header)
        try await writer.close()

        await #expect(throws: JSONLWriterError.self) {
            let seg = Segment(source: .mic, timestamp: Date(), duration: 0.1, text: "late")
            try await writer.write(seg)
        }
    }
}
