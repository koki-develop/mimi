import Foundation

public enum Speaker: Sendable, Hashable {
    case me
    case others

    /// The label shown to the user and used in prompts.
    public var displayName: String {
        switch self {
        case .me: "自分"
        case .others: "相手"
        }
    }
}

/// Merges transcription results from multiple speakers into a single timeline.
public struct Transcript: Sendable {
    public struct Line: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var speaker: Speaker
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval
        public var isFinal: Bool
    }

    /// Consecutive lines from the same speaker.
    public struct Turn: Identifiable, Sendable, Equatable {
        public var speaker: Speaker
        /// Ordered by start time. Never empty.
        public var lines: [Line]

        /// The ID of the first line, which stays the same as later lines join the turn.
        public var id: UUID {
            lines[0].id
        }

        /// Whether the speaker is still speaking, i.e. the last line has not been finalized yet.
        public var isInProgress: Bool {
            !lines[lines.count - 1].isFinal
        }
    }

    public private(set) var finalLines: [Line] = []
    /// ``finalLines`` grouped into turns, kept in step as lines are finalized.
    private var finalTurns: [Turn] = []
    private var volatileLines: [Speaker: Line] = [:]

    public init() {}

    /// Final lines followed by in-progress lines, each ordered by start time.
    public var lines: [Line] {
        finalLines + sortedVolatileLines
    }

    /// The last of ``lines``.
    public var latestLine: Line? {
        volatileLines.values.max { $0.start < $1.start } ?? finalLines.last
    }

    /// ``lines`` grouped into turns, in the same order.
    public var turns: [Turn] {
        var turns = finalTurns
        for line in sortedVolatileLines {
            Self.append(line, to: &turns)
        }
        return turns
    }

    private var sortedVolatileLines: [Line] {
        volatileLines.values.sorted { $0.start < $1.start }
    }

    private static func append(_ line: Line, to turns: inout [Turn]) {
        if let last = turns.indices.last, turns[last].speaker == line.speaker {
            turns[last].lines.append(line)
        } else {
            turns.append(Turn(speaker: line.speaker, lines: [line]))
        }
    }

    public mutating func apply(_ result: TranscriptionResult, from speaker: Speaker) {
        // An overlapping result supersedes the volatile line and keeps its ID, since both describe the same speech.
        var id = UUID()
        if let previous = volatileLines.removeValue(forKey: speaker) {
            if previous.end <= result.start {
                // A volatile result that is not superseded by an overlapping result has been finalized as-is.
                appendFinal(Line(id: previous.id, speaker: speaker, text: previous.text, start: previous.start, end: previous.end, isFinal: true))
            } else {
                id = previous.id
            }
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = Line(id: id, speaker: speaker, text: text, start: result.start, end: result.end, isFinal: result.isFinal)
        if result.isFinal {
            appendFinal(line)
        } else {
            volatileLines[speaker] = line
        }
    }

    private mutating func appendFinal(_ line: Line) {
        let index = finalLines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        finalLines.insert(line, at: index)
        if index == finalLines.count - 1 {
            Self.append(line, to: &finalTurns)
        } else {
            // A line that started before others regroups the turns around it.
            finalTurns = []
            for line in finalLines {
                Self.append(line, to: &finalTurns)
            }
        }
    }
}
