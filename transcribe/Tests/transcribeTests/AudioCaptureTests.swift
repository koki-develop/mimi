import Foundation
import Testing

@testable import transcribe

@Suite struct AudioCaptureTests {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "transcribe-test-\(UUID().uuidString).jsonl")
  }

  @Test func outputHandlerQueueLabelUsesExpectedBundleIdentifierPrefix() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try JSONLWriter(output: url)
    let console = ConsoleReporter(stream: StringStream())
    let logger = EventLogger(writer: writer, console: console)

    let tracker = AudioCapture.SessionStartTracker()
    let continuation = AsyncStream<CapturedAudioChunk>.makeStream().continuation

    let micOutput = AudioCapture.OutputHandler(
      source: .mic,
      continuation: continuation,
      reporter: logger,
      verbose: false,
      sessionStart: tracker
    )

    #expect(micOutput.queue.label == "me.koki.transcribe.capture.mic")
  }

  @Test func streamErrorBoxKeepsFirstError() {
    let box = AudioCapture.StreamErrorBox()
    let first = TestError(label: "first")
    let second = TestError(label: "second")
    box.trySet(first)
    box.trySet(second)
    let taken = box.take()
    #expect((taken as? TestError)?.label == "first")
  }

  @Test func streamErrorBoxTakeClearsStorage() {
    let box = AudioCapture.StreamErrorBox()
    box.trySet(TestError(label: "only"))
    _ = box.take()
    // 2 度目の take は nil
    #expect(box.take() == nil)
  }

  @Test func streamErrorBoxTakeReturnsNilWhenEmpty() {
    let box = AudioCapture.StreamErrorBox()
    #expect(box.take() == nil)
  }
}

private struct TestError: Error, Equatable {
  let label: String
}

private struct StringStream: TextOutputStream, Sendable {
  mutating func write(_ string: String) {}
}
