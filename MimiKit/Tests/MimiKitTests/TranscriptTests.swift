import MimiKit
import Testing

struct TranscriptTests {
    private func result(_ text: String, _ start: Double, _ end: Double, final isFinal: Bool) -> TranscriptionResult {
        TranscriptionResult(text: text, start: start, end: end, isFinal: isFinal)
    }

    private func texts(_ transcript: Transcript) -> [String] {
        transcript.lines.map(\.text)
    }

    @Test func volatileResultIsReplacedByOverlappingResult() {
        var transcript = Transcript()
        transcript.apply(result("こんに", 0, 1, final: false), from: .me)
        transcript.apply(result("こんにちは", 0, 2, final: false), from: .me)
        #expect(texts(transcript) == ["こんにちは"])
        #expect(transcript.lines.map(\.isFinal) == [false])

        transcript.apply(result("こんにちは。", 0, 2, final: true), from: .me)
        #expect(texts(transcript) == ["こんにちは。"])
        #expect(transcript.lines.map(\.isFinal) == [true])
    }

    @Test func volatileResultIsPromotedWhenFollowedByLaterResult() {
        var transcript = Transcript()
        transcript.apply(result("はい", 0, 1, final: false), from: .me)
        transcript.apply(result("次の話", 2, 3, final: false), from: .me)
        #expect(texts(transcript) == ["はい", "次の話"])
        #expect(transcript.lines.map(\.isFinal) == [true, false])
    }

    @Test func speakersAreMergedByStartTime() {
        var transcript = Transcript()
        transcript.apply(result("相手1", 0, 1, final: true), from: .others)
        transcript.apply(result("相手2", 4, 5, final: true), from: .others)
        transcript.apply(result("自分1", 2, 3, final: true), from: .me)
        #expect(texts(transcript) == ["相手1", "自分1", "相手2"])
        #expect(transcript.lines.map(\.speaker) == [.others, .me, .others])
    }

    @Test func volatileLinesFollowFinalLines() {
        var transcript = Transcript()
        transcript.apply(result("相手の途中", 1, 2, final: false), from: .others)
        transcript.apply(result("自分の確定", 3, 4, final: true), from: .me)
        transcript.apply(result("自分の途中", 0.5, 5, final: false), from: .me)
        #expect(texts(transcript) == ["自分の確定", "自分の途中", "相手の途中"])
    }

    @Test func blankResultsAreIgnored() {
        var transcript = Transcript()
        transcript.apply(result("  ", 0, 1, final: true), from: .me)
        #expect(transcript.lines.isEmpty)
    }
}
