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

    @Test func supersedingResultKeepsLineID() throws {
        var transcript = Transcript()
        transcript.apply(result("こんに", 0, 1, final: false), from: .me)
        let id = try #require(transcript.lines.first).id
        transcript.apply(result("こんにちは", 0, 2, final: false), from: .me)
        #expect(transcript.lines.map(\.id) == [id])
        transcript.apply(result("こんにちは。", 0, 2, final: true), from: .me)
        #expect(transcript.lines.map(\.id) == [id])
    }

    @Test func laterResultGetsNewLineID() throws {
        var transcript = Transcript()
        transcript.apply(result("はい", 0, 1, final: false), from: .me)
        let id = try #require(transcript.lines.first).id
        transcript.apply(result("次の話", 2, 3, final: false), from: .me)
        #expect(transcript.lines.first?.id == id)
        #expect(transcript.lines.last?.id != id)
    }

    @Test func blankSupersedingResultRemovesVolatileLine() {
        var transcript = Transcript()
        transcript.apply(result("えっと", 0, 1, final: false), from: .me)
        transcript.apply(result(" ", 0, 1, final: true), from: .me)
        #expect(transcript.lines.isEmpty)
    }

    @Test func consecutiveLinesFromSameSpeakerFormTurns() {
        var transcript = Transcript()
        transcript.apply(result("相手1", 0, 1, final: true), from: .others)
        transcript.apply(result("相手2", 1, 2, final: true), from: .others)
        transcript.apply(result("自分1", 2, 3, final: true), from: .me)
        transcript.apply(result("相手3", 3, 4, final: true), from: .others)
        #expect(transcript.turns.map(\.speaker) == [.others, .me, .others])
        #expect(transcript.turns.map { $0.lines.map(\.text) } == [["相手1", "相手2"], ["自分1"], ["相手3"]])
    }

    @Test func turnIsInProgressWhileItsLastLineIsVolatile() {
        var transcript = Transcript()
        transcript.apply(result("相手1", 0, 1, final: true), from: .others)
        transcript.apply(result("相手の途中", 1, 2, final: false), from: .others)
        #expect(transcript.turns.map(\.isInProgress) == [true])
        #expect(transcript.turns.first?.lines.map(\.text) == ["相手1", "相手の途中"])

        transcript.apply(result("相手の確定", 1, 2, final: true), from: .others)
        #expect(transcript.turns.map(\.isInProgress) == [false])
    }

    @Test func turnIDStaysWhileTheTurnGrows() throws {
        var transcript = Transcript()
        transcript.apply(result("自分1", 0, 1, final: true), from: .me)
        let id = try #require(transcript.turns.first).id
        transcript.apply(result("自分の途中", 1, 2, final: false), from: .me)
        transcript.apply(result("自分2", 1, 2, final: true), from: .me)
        #expect(transcript.turns.map(\.id) == [id])
    }

    @Test func lateFinalLineRegroupsTurns() {
        var transcript = Transcript()
        transcript.apply(result("相手1", 0, 1, final: true), from: .others)
        transcript.apply(result("相手2", 4, 5, final: true), from: .others)
        #expect(transcript.turns.map { $0.lines.map(\.text) } == [["相手1", "相手2"]])

        transcript.apply(result("自分1", 2, 3, final: true), from: .me)
        #expect(transcript.turns.map { $0.lines.map(\.text) } == [["相手1"], ["自分1"], ["相手2"]])
    }

    @Test func volatileLineJoinsTheLastFinalTurnOfItsSpeaker() {
        var transcript = Transcript()
        transcript.apply(result("自分1", 0, 1, final: true), from: .me)
        transcript.apply(result("自分の途中", 1, 2, final: false), from: .me)
        transcript.apply(result("相手の途中", 1.5, 3, final: false), from: .others)
        #expect(transcript.turns.map { $0.lines.map(\.text) } == [["自分1", "自分の途中"], ["相手の途中"]])
    }

    @Test func latestLineIsTheLastOfLines() {
        var transcript = Transcript()
        #expect(transcript.latestLine == nil)
        transcript.apply(result("相手の確定", 0, 1, final: true), from: .others)
        #expect(transcript.latestLine == transcript.lines.last)
        transcript.apply(result("自分の途中", 0.5, 2, final: false), from: .me)
        transcript.apply(result("相手の途中", 1, 3, final: false), from: .others)
        #expect(transcript.latestLine == transcript.lines.last)
        #expect(transcript.latestLine?.text == "相手の途中")
    }

    @Test func blankResultsAreIgnored() {
        var transcript = Transcript()
        transcript.apply(result("  ", 0, 1, final: true), from: .me)
        #expect(transcript.lines.isEmpty)
    }
}
