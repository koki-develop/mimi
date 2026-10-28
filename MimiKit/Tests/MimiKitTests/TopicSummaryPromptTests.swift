import Foundation
@testable import MimiKit
import Testing

struct TopicSummaryPromptTests {
    private func line(_ text: String, clipped isClipped: Bool = false, final isFinal: Bool = true) -> TranscriptExcerpt.Line {
        TranscriptExcerpt.Line(speaker: .me, text: text, isClipped: isClipped, isFinal: isFinal)
    }

    @Test func marksLinesInProgress() {
        #expect(TopicSummaryPrompt.format(line("確定した発言")) == "自分: 確定した発言")
        #expect(TopicSummaryPrompt.format(line("話している途中", final: false)) == "自分\(TopicSummaryPrompt.inProgressMarker): 話している途中")
    }

    @Test func marksClippedLines() {
        #expect(TopicSummaryPrompt.format(line("末尾", clipped: true)) == "自分: \(TopicSummaryPrompt.clippedMarker)末尾")
    }

    @Test func instructionsExplainTheMarkers() {
        #expect(TopicSummaryPrompt.instructions.contains(TopicSummaryPrompt.inProgressMarker))
        #expect(TopicSummaryPrompt.instructions.contains(TopicSummaryPrompt.clippedMarker))
    }

    @Test func promptListsTheLinesInOrder() {
        let excerpt = TranscriptExcerpt(of: [
            Transcript.Line(id: UUID(), speaker: .others, text: "一つ目", start: 0, end: 1, isFinal: true),
            Transcript.Line(id: UUID(), speaker: .me, text: "二つ目", start: 1, end: 2, isFinal: false),
        ], characterLimit: 100)
        let prompt = TopicSummaryPrompt.prompt(for: excerpt)
        #expect(prompt.contains(excerpt.lines.map(TopicSummaryPrompt.format).joined(separator: "\n")))
    }
}
