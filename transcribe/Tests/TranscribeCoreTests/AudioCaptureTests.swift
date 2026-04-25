import Testing

@testable import TranscribeCore

@Suite struct AudioCaptureTests {
  @Test func audioOutputTapQueueLabelUsesExpectedBundleIdentifierPrefix() {
    let tracker = SessionStartTracker()
    let continuation = AsyncStream<CapturedAudioChunk>.makeStream().continuation
    let diagnosticContinuation = AsyncStream<CaptureDiagnostic>.makeStream().continuation

    let micOutput = AudioOutputTap(
      source: .mic,
      continuation: continuation,
      diagnosticContinuation: diagnosticContinuation,
      verbose: false,
      sessionStart: tracker
    )

    #expect(micOutput.queue.label == "me.koki.transcribe.capture.mic")
  }

  @Test func streamErrorBoxKeepsFirstError() {
    let box = StreamErrorBox()
    let first = TestError(label: "first")
    let second = TestError(label: "second")
    box.trySet(first)
    box.trySet(second)
    let taken = box.take()
    #expect((taken as? TestError)?.label == "first")
  }

  @Test func streamErrorBoxTakeClearsStorage() {
    let box = StreamErrorBox()
    box.trySet(TestError(label: "only"))
    _ = box.take()
    // 2 度目の take は nil
    #expect(box.take() == nil)
  }

  @Test func streamErrorBoxTakeReturnsNilWhenEmpty() {
    let box = StreamErrorBox()
    #expect(box.take() == nil)
  }
}

private struct TestError: Error, Equatable {
  let label: String
}
