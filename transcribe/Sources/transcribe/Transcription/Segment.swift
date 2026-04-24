import Foundation

public enum AudioSource: String, Sendable, Codable {
    case mic
    case system
}

public struct Segment: Sendable, Equatable {
    public let source: AudioSource
    public let timestamp: Date
    public let duration: Double
    public let text: String

    public init(source: AudioSource, timestamp: Date, duration: Double, text: String) {
        self.source = source
        self.timestamp = timestamp
        self.duration = duration
        self.text = text
    }
}

/// ISO8601(fractional seconds + local TZ)の相互変換ヘルパ。
/// `Event` の Codable 実装が JSONL の timestamp 表現として使用する。
struct ISO8601Format: Sendable {
    static let shared = ISO8601Format()

    func string(from date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    func date(from string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: string)
    }
}
