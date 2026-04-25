import Foundation

/// ISO8601 (fractional seconds + local TZ) の相互変換ヘルパ。
/// `Event` の Codable 実装が JSONL の timestamp 表現として使用する。
enum Timestamp {
  static func string(from date: Date) -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    fmt.timeZone = .current
    return fmt.string(from: date)
  }

  static func date(from string: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: string)
  }
}
