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

    public private(set) var finalLines: [Line] = []
    private var volatileLines: [Speaker: Line] = [:]

    public init() {}

    /// Final lines followed by in-progress lines, each ordered by start time.
    public var lines: [Line] {
        finalLines + volatileLines.values.sorted { $0.start < $1.start }
    }

    public mutating func apply(_ result: TranscriptionResult, from speaker: Speaker) {
        if let previous = volatileLines.removeValue(forKey: speaker), previous.end <= result.start {
            // A volatile result that is not superseded by an overlapping result has been finalized as-is.
            appendFinal(Line(id: previous.id, speaker: speaker, text: previous.text, start: previous.start, end: previous.end, isFinal: true))
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let line = Line(id: UUID(), speaker: speaker, text: text, start: result.start, end: result.end, isFinal: result.isFinal)
        if result.isFinal {
            appendFinal(line)
        } else {
            volatileLines[speaker] = line
        }
    }

    private mutating func appendFinal(_ line: Line) {
        let index = finalLines.lastIndex { $0.start <= line.start }.map { $0 + 1 } ?? 0
        finalLines.insert(line, at: index)
    }
}
