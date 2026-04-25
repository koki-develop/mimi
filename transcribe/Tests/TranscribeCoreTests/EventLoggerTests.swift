import Foundation
import Testing

@testable import TranscribeCore

@Suite struct EventLoggerTests {
  final class InMemoryStream: TextOutputStream, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func write(_ string: String) {
      lock.lock()
      defer { lock.unlock() }
      buffer += string
    }
    var content: String {
      lock.lock()
      defer { lock.unlock() }
      return buffer
    }
  }

  private func makeLogger() -> (EventLogger, RecordingEventSink, InMemoryStream) {
    let sink = RecordingEventSink()
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(sink: sink, console: console)
    return (logger, sink, stream)
  }

  @Test func sessionStartedEmitsEventOnly() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.sessionStarted(model: "m")
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .sessionStarted(_, let data) = events[0] {
      #expect(data.model == "m")
    } else {
      Issue.record("expected sessionStarted, got \(events[0])")
    }
    #expect(stream.content.isEmpty)
  }

  @Test func stateChangedEmitsEventOnly() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.stateChanged(.capturing)
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .stateChanged(_, let data) = events[0] {
      #expect(data.state == .capturing)
    } else {
      Issue.record("expected stateChanged, got \(events[0])")
    }
    #expect(stream.content.isEmpty)
  }

  @Test func sessionStoppedEmitsEventOnly() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.sessionStopped(reason: .stop)
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .sessionStopped(_, let data) = events[0] {
      #expect(data.reason == .stop)
    } else {
      Issue.record("expected sessionStopped, got \(events[0])")
    }
    #expect(stream.content.isEmpty)
  }

  @Test func warningEmitsEventAndConsole() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.warning("slow network")
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .warning(_, let data) = events[0] {
      #expect(data.message == "slow network")
    } else {
      Issue.record("expected warning, got \(events[0])")
    }
    #expect(stream.content.contains("Warning: slow network"))
  }

  @Test func errorEmitsEventAndConsole() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.error("boom")
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .error(_, let data) = events[0] {
      #expect(data.message == "boom")
    } else {
      Issue.record("expected error, got \(events[0])")
    }
    #expect(stream.content.contains("Error: boom"))
  }

  @Test func reportEmitsSegmentAndConsole() async throws {
    let (logger, sink, stream) = makeLogger()
    let seg = Segment(
      source: .mic,
      timestamp: Date(timeIntervalSince1970: 1_234_567_890),
      duration: 1.5,
      text: "hello"
    )
    await logger.report(seg)
    let events = sink.recordedEvents()
    #expect(events.count == 1)
    if case .segment(_, let data) = events[0] {
      #expect(data.source == .mic)
      #expect(data.text == "hello")
      #expect(data.duration == 1.5)
    } else {
      Issue.record("expected segment, got \(events[0])")
    }
    // ConsoleReporter prints something for segments (existing behavior).
    #expect(!stream.content.isEmpty)
  }

  @Test func statusMessageGoesToConsoleOnly() async throws {
    let (logger, sink, stream) = makeLogger()
    await logger.statusMessage("Loading model (foo)...")
    #expect(sink.recordedEvents().isEmpty)
    #expect(stream.content.contains("Loading model (foo)..."))
  }

  @Test func sinkWriteFailureNotifiesStderrOnceAndFlagsFlushedWithErrors() async throws {
    final class FailingSink: EventSink, @unchecked Sendable {
      func write(_ event: Event) async throws { throw RecordingEventSinkError.closed }
      func close() async throws {}
    }
    let stream = InMemoryStream()
    let console = ConsoleReporter(stream: stream)
    let logger = EventLogger(sink: FailingSink(), console: console)

    await logger.sessionStarted(model: "m")
    await logger.sessionStarted(model: "m")  // second failure should not double-log
    #expect(await logger.flushedWithErrors())
    let occurrences = stream.content.components(separatedBy: "event sink write failed").count - 1
    #expect(occurrences == 1)
  }
}
