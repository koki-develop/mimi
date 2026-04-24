import Foundation
import Testing
@testable import transcribe

@Suite struct JSONLWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-test-\(UUID().uuidString).jsonl")
    }

    @Test func createsFileAndWritesEvents() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLWriter(output: url)
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let events: [Event] = [
            .sessionStarted(timestamp: ts, data: SessionStartedData(model: "m")),
            .segment(timestamp: ts, data: SegmentData(source: .mic, duration: 1.0, text: "hi")),
            .sessionStopped(timestamp: ts, data: SessionStoppedData(reason: .sigint)),
        ]
        for event in events {
            try await writer.write(event)
        }
        try await writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 4)
        #expect(lines[3] == "")

        // 文字列 contains ではなく実際に Event として decode し、構造的に一致することを検証。
        // これにより "data" が JSON 文字列に化けるような regression も捕捉できる。
        let decoder = JSONDecoder()
        for (i, event) in events.enumerated() {
            let decoded = try decoder.decode(Event.self, from: lines[i].data(using: .utf8)!)
            #expect(decoded == event, "line \(i) round-trip failed for \(event.typeString)")
        }
    }

    @Test func throwsWhenOutputAlreadyExists() throws {
        let url = tempURL()
        try "existing".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: JSONLWriterError.self) {
            _ = try JSONLWriter(output: url)
        }
    }

    @Test func preservesInsertionOrder() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLWriter(output: url)
        let ts = Date()
        for i in 0..<20 {
            try await writer.write(.segment(
                timestamp: ts,
                data: SegmentData(source: .mic, duration: 0.1, text: "msg-\(i)")
            ))
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

        let writer = try JSONLWriter(output: url)
        try await writer.close()

        await #expect(throws: JSONLWriterError.self) {
            try await writer.write(.warning(
                timestamp: Date(),
                data: WarningData(message: "late")
            ))
        }
    }

    @Test func closeIsIdempotent() async throws {
        // App.run は happy path / fail path の両方から closeWriter を呼び得るため、
        // 2 度目の close() が throw せず no-op であることを保証する。
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLWriter(output: url)
        try await writer.close()
        try await writer.close() // 2 度目: no-op
    }

    @Test func concurrentWritesProduceValidLines() async throws {
        // spec line 54 が「JSONL の書き込み自体は actor でシリアライズされる」と
        // 保証している。actor を外すような regression を捕捉するため、複数 task から
        // 並列に write し、各 line が単体で valid な Event として decode 可能であること
        // (line の interleave が無いこと)を検証する。
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try JSONLWriter(output: url)
        let count = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    // 各 task で別 source / text を持つ segment を 1 本書く
                    let seg = Event.segment(
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                        data: SegmentData(
                            source: i % 2 == 0 ? .mic : .system,
                            duration: 0.1,
                            text: "concurrent-\(i)"
                        )
                    )
                    try? await writer.write(seg)
                }
            }
            await group.waitForAll()
        }
        try await writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == count)

        let decoder = JSONDecoder()
        var seenTexts: Set<String> = []
        for line in lines {
            // actor でシリアライズされていれば各 line は完結した 1 つの Event JSON になる。
            let event = try decoder.decode(Event.self, from: line.data(using: .utf8)!)
            guard case .segment(_, let data) = event else {
                Issue.record("unexpected event type: \(event.typeString)")
                continue
            }
            #expect(data.text.hasPrefix("concurrent-"))
            seenTexts.insert(data.text)
        }
        #expect(seenTexts.count == count, "expected \(count) distinct segments, got \(seenTexts.count)")
    }
}
