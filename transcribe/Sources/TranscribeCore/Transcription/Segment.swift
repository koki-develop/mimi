import Foundation

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
