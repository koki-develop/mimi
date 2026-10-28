import Foundation
@testable import MimiKit
import Testing

struct TranscriptExcerptTests {
    private func lines(_ lines: [(Speaker, String, isFinal: Bool)]) -> [Transcript.Line] {
        lines.enumerated().map { index, line in
            let start = Double(index)
            return Transcript.Line(id: UUID(), speaker: line.0, text: line.1, start: start, end: start + 1, isFinal: line.isFinal)
        }
    }

    private func line(_ speaker: Speaker, _ text: String, clipped isClipped: Bool = false, final isFinal: Bool = true) -> TranscriptExcerpt.Line {
        TranscriptExcerpt.Line(speaker: speaker, text: text, isClipped: isClipped, isFinal: isFinal)
    }

    @Test func isEmptyWithoutLines() {
        #expect(TranscriptExcerpt(of: [], characterLimit: 10).lines.isEmpty)
    }

    @Test func keepsRecentLinesThatFillTheLimit() {
        let transcript = lines([(.others, "古い発言です", true), (.me, "新しい", true), (.others, "最新", true)])
        let excerpt = TranscriptExcerpt(of: transcript, characterLimit: 5)
        #expect(excerpt.lines == [line(.me, "新しい"), line(.others, "最新")])
    }

    @Test func dropsAnEarlierLineThatDoesNotFit() {
        let transcript = lines([(.me, "短い", true), (.others, "古い発言です", true), (.me, "最新", true)])
        let excerpt = TranscriptExcerpt(of: transcript, characterLimit: 5)
        #expect(excerpt.lines == [line(.me, "最新")])
    }

    @Test func clipsTheLatestLineOverTheLimit() {
        let transcript = lines([(.others, "前の発言", true), (.me, "とても長い話し中の発言", false)])
        let excerpt = TranscriptExcerpt(of: transcript, characterLimit: 4)
        #expect(excerpt.lines == [line(.me, "中の発言", clipped: true, final: false)])
    }

    @Test func keepsWholeCharacters() {
        let transcript = lines([(.me, "家族👨‍👩‍👧", true)])
        let excerpt = TranscriptExcerpt(of: transcript, characterLimit: 1)
        #expect(excerpt.lines == [line(.me, "👨‍👩‍👧", clipped: true)])
    }
}
