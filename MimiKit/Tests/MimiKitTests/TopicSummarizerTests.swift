import MimiKit
import Synchronization
import Testing

private final class RecordingGenerator: TextGenerator {
    let prompts = Mutex<[String]>([])

    func generate(instructions: String, prompt: String) async throws -> String {
        let count = prompts.withLock {
            $0.append(prompt)
            return $0.count
        }
        return " 応答\(count) \n"
    }
}

struct TopicSummarizerTests {
    private func transcript(_ lines: [(Speaker, String)]) -> Transcript {
        var transcript = Transcript()
        for (index, (speaker, text)) in lines.enumerated() {
            let start = Double(index)
            transcript.apply(TranscriptionResult(text: text, start: start, end: start + 1, isFinal: true), from: speaker)
        }
        return transcript
    }

    @Test func returnsNilWithoutNewLines() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator)
        #expect(try await summarizer.update(with: []) == nil)

        let lines = transcript([(.me, "こんにちは")]).finalLines
        #expect(try await summarizer.update(with: lines) == "応答1")
        #expect(try await summarizer.update(with: lines) == nil)
        #expect(generator.prompts.withLock { $0.count } == 1)
    }

    @Test func usesRecentLinesWithinLimit() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator, recentCharacterLimit: 6)
        let lines = transcript([(.others, "古い発言です"), (.me, "新しい"), (.others, "最新")]).finalLines
        _ = try await summarizer.update(with: lines)

        let prompt = generator.prompts.withLock { $0[0] }
        #expect(prompt.contains("自分: 新しい\n相手: 最新"))
        #expect(!prompt.contains("古い発言です"))
    }

    @Test func keepsLatestLineEvenIfOverLimit() async throws {
        let generator = RecordingGenerator()
        let summarizer = TopicSummarizer(generator: generator, recentCharacterLimit: 2)
        let lines = transcript([(.others, "とても長い最新の発言")]).finalLines
        _ = try await summarizer.update(with: lines)

        let prompt = generator.prompts.withLock { $0[0] }
        #expect(prompt.contains("相手: とても長い最新の発言"))
    }
}
