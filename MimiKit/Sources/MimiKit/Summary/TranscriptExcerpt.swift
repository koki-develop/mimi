import Foundation

/// The most recent part of a transcript, whose text adds up to at most a character limit.
struct TranscriptExcerpt: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        var speaker: Speaker
        /// The end of the line's text, which is all of it unless ``isClipped``.
        var text: String
        /// Whether the beginning of the line's text is left out to stay within the limit.
        var isClipped: Bool
        var isFinal: Bool
    }

    /// In the order of the transcript. A clipped line is the only line.
    var lines: [Line]

    /// The lines are taken whole from the end of `lines`, up to the first that does not fit. The last line alone is
    /// clipped to the end of its text when it does not fit, so that the excerpt never holds a fragment of an earlier line.
    init(of lines: [Transcript.Line], characterLimit: Int) {
        var remaining = characterLimit
        var excerpt: [Line] = []
        for line in lines.reversed() {
            let count = line.text.count
            if count <= remaining {
                excerpt.append(Line(speaker: line.speaker, text: line.text, isClipped: false, isFinal: line.isFinal))
                remaining -= count
            } else {
                if excerpt.isEmpty, remaining > 0 {
                    excerpt.append(Line(speaker: line.speaker, text: String(line.text.suffix(remaining)), isClipped: true, isFinal: line.isFinal))
                }
                break
            }
        }
        self.lines = excerpt.reversed()
    }
}
