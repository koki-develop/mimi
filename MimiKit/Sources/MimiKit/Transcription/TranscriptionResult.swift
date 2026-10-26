import Foundation

public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var isFinal: Bool

    public init(text: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }
}
