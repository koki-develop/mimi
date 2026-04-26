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

  // shouldDropFrame: pure function 切り出し版の網羅テスト。
  // ここでフィルタ判定の不変条件をピン留めしておけば、将来 condition 反転や
  // nil-passthrough 抜けが入った場合に CI で気付ける。

  @Test func shouldDropFrameReturnsFalseWhenStateIsNil() {
    // system tap は micEnabledState を持たない。常に通す。
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: nil) == false)
  }

  @Test func shouldDropFrameReturnsFalseWhenEnabled() {
    let state = MicEnabledState(initiallyEnabled: true)
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: state) == false)
  }

  @Test func shouldDropFrameReturnsTrueWhenDisabled() {
    let state = MicEnabledState(initiallyEnabled: false)
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: state) == true)
  }

  @Test func shouldDropFrameReflectsMidLifetimeToggle() {
    let state = MicEnabledState(initiallyEnabled: true)
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: state) == false)
    state.setEnabled(false)
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: state) == true)
    state.setEnabled(true)
    #expect(AudioOutputTap.shouldDropFrame(micEnabledState: state) == false)
  }
}

private struct TestError: Error, Equatable {
  let label: String
}
