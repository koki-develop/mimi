import Foundation

public enum AudioSource: String, Sendable, Codable {
    case mic
    case system
}

public struct Segment: Sendable, Codable, Equatable {
    public let type: String
    public let source: AudioSource
    public let timestamp: Date
    public let duration: Double
    public let text: String

    public init(source: AudioSource, timestamp: Date, duration: Double, text: String) {
        self.type = "segment"
        self.source = source
        self.timestamp = timestamp
        self.duration = duration
        self.text = text
    }
}

public enum JSONLSerializer {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Format.shared.string(from: date))
        }
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            guard let date = ISO8601Format.shared.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(s)")
            }
            return date
        }
        return try decoder.decode(T.self, from: data)
    }
}

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
