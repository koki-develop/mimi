import Foundation

/// `EventLogger` が `Event` を「どこかに永続化する」ための抽象。
/// production: `StdoutEventWriter` (stdout)。test: `RecordingEventSink`。
public protocol EventSink: Sendable {
  func write(_ event: Event) async throws
  func close() async throws
}
