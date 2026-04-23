import Foundation
import Testing
@testable import transcribe

@Suite struct ConsoleReporterTests {
    final class InMemoryStream: TextOutputStream, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func write(_ string: String) {
            lock.lock(); defer { lock.unlock() }
            buffer += string
        }
        var content: String {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }

    @Test func reportsSegmentInSpecFormat() async {
        let stream = InMemoryStream()
        let reporter = ConsoleReporter(stream: stream)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let seg = Segment(source: .mic, timestamp: ts, duration: 1.0, text: "こんにちは")
        await reporter.report(seg)

        let content = stream.content
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("[mic] "))
        #expect(lines[0].contains("こんにちは"))
        #expect(lines[0].range(of: #"\d{2}:\d{2}:\d{2}\.\d"#, options: .regularExpression) != nil)
    }

    @Test func reportsSystemSource() async {
        let stream = InMemoryStream()
        let reporter = ConsoleReporter(stream: stream)
        let seg = Segment(source: .system, timestamp: Date(), duration: 1.0, text: "x")
        await reporter.report(seg)
        #expect(stream.content.hasPrefix("[sys] "))
    }

    @Test func reportsStatusWarningAndError() async {
        let stream = InMemoryStream()
        let reporter = ConsoleReporter(stream: stream)

        await reporter.reportStatus("Ready.")
        await reporter.reportWarning("slow network")
        await reporter.reportError("Boom.")

        let lines = stream.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines.contains("Ready."))
        #expect(lines.contains("Warning: slow network"))
        #expect(lines.contains("Error: Boom."))
    }
}
