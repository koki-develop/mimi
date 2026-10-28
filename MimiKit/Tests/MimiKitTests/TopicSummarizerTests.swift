import MimiKit
import Synchronization
import Testing

private final class RecordingGenerator: TextGenerator {
    let prompts = Mutex<[String]>([])
    /// The number of upcoming calls that fail.
    let failures = Mutex(0)

    func generate(instructions: String, prompt: String) async throws -> String {
        let count = prompts.withLock {
            $0.append(prompt)
            return $0.count
        }
        let fails = failures.withLock { failures in
            defer { failures = max(failures - 1, 0) }
            return failures > 0
        }
        if fails { throw TestError() }
        return " 応答\(count) \n"
    }

    var promptCount: Int {
        prompts.withLock { $0.count }
    }

    var lastPrompt: String? {
        prompts.withLock { $0.last }
    }
}

private struct TestError: Error {}

struct TopicSummarizerTests {
    private func transcript(_ lines: [(Speaker, String)]) -> Transcript {
        var transcript = Transcript()
        for (index, (speaker, text)) in lines.enumerated() {
            let start = Double(index)
            transcript.apply(TranscriptionResult(text: text, start: start, end: start + 1, isFinal: true), from: speaker)
        }
        return transcript
    }

    @Test func returnsNilWithoutLines() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator)
        #expect(try await summarizer.update(with: []) == nil)
        #expect(generator.promptCount == 0)
    }

    @Test func returnsNilWhileRecentLinesStayTheSame() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator)
        let lines = transcript([(.me, "こんにちは")]).lines
        #expect(try await summarizer.update(with: lines) == "応答1")
        #expect(try await summarizer.update(with: lines) == nil)
        #expect(generator.promptCount == 1)
    }

    @Test func summarizesLinesInProgress() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator)
        var transcript = Transcript()
        transcript.apply(TranscriptionResult(text: "話している途中", start: 0, end: 1, isFinal: false), from: .others)

        #expect(try await summarizer.update(with: transcript.lines) == "応答1")
        #expect(generator.lastPrompt?.contains("話している途中") == true)
    }

    @Test func summarizesAgainAsALineInProgressGrows() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator)
        var transcript = Transcript()
        transcript.apply(TranscriptionResult(text: "予算の", start: 0, end: 1, isFinal: false), from: .others)
        _ = try await summarizer.update(with: transcript.lines)

        transcript.apply(TranscriptionResult(text: "予算の見直しについて", start: 0, end: 2, isFinal: false), from: .others)
        #expect(try await summarizer.update(with: transcript.lines) == "応答2")
        #expect(generator.lastPrompt?.contains("予算の見直しについて") == true)
    }

    @Test func retriesAfterAFailedSummary() async throws {
        let generator = RecordingGenerator()
        generator.failures.withLock { $0 = 1 }
        let summarizer = TopicSummarizer(generator: generator)
        let lines = transcript([(.me, "こんにちは")]).lines

        await #expect(throws: TestError.self) { try await summarizer.update(with: lines) }
        #expect(try await summarizer.update(with: lines) == "応答2")
    }

    @Test func usesRecentLinesWithinLimit() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator, recentCharacterLimit: 5)
        let lines = transcript([(.others, "古い発言です"), (.me, "新しい"), (.others, "最新")]).lines
        _ = try await summarizer.update(with: lines)

        let prompt = try #require(generator.lastPrompt)
        #expect(prompt.contains("自分: 新しい\n相手: 最新"))
        #expect(!prompt.contains("古い"))
    }

    @Test func clipsTheLatestLineOverLimit() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator, recentCharacterLimit: 3)
        let lines = transcript([(.others, "とても長い最新の発言")]).lines
        _ = try await summarizer.update(with: lines)

        let prompt = try #require(generator.lastPrompt)
        #expect(prompt.contains("の発言"))
        #expect(!prompt.contains("最新"))
    }
}
