import Foundation
import Testing

@testable import TranscribeCore

@Suite struct ShutdownCoordinatorTests {

  // MARK: - actor の record* と finalize

  @Test func recordSegmentIncrementsCounter() async {
    let c = ShutdownCoordinator()
    await c.recordSegment()
    await c.recordSegment()
    await c.recordSegment()
    let outcome = await c.finalize(streamError: nil)
    #expect(outcome.segmentCount == 3)
  }

  @Test func sigintBeatsConsumerEOF() async {
    let c = ShutdownCoordinator()
    await c.recordSIGINT()
    await c.recordConsumerEOF()
    let outcome = await c.finalize(streamError: nil)
    #expect(outcome.reason == .sigint)
    if case .sigint = outcome {} else { Issue.record("expected .sigint outcome") }
  }

  @Test func consumerEOFBeforeSigintStillSetsError() async {
    let c = ShutdownCoordinator()
    await c.recordConsumerEOF()
    await c.recordSIGINT()  // tryset 後なので無視される
    let outcome = await c.finalize(streamError: nil)
    #expect(outcome.reason == .error)
    if case .error(let message, _) = outcome {
      #expect(message == nil)
    } else {
      Issue.record("expected .error outcome")
    }
  }

  @Test func streamErrorInFinalizeOverridesSigint() async {
    struct E: Error {}
    let c = ShutdownCoordinator()
    await c.recordSIGINT()
    let outcome = await c.finalize(streamError: E())
    #expect(outcome.reason == .error)
    if case .error(let message, _) = outcome {
      #expect(message?.contains("Capture stopped unexpectedly") == true)
    } else {
      Issue.record("expected .error outcome with message")
    }
  }

  @Test func noStreamErrorMeansNilErrorMessage() async {
    let c = ShutdownCoordinator()
    await c.recordSIGINT()
    let outcome = await c.finalize(streamError: nil)
    if case .sigint = outcome {} else { Issue.record("expected .sigint outcome") }
  }

  @Test func defaultReasonWhenNothingRecorded() async {
    let c = ShutdownCoordinator()
    let outcome = await c.finalize(streamError: nil)
    // 何も record しなければ default は .error (既存挙動を保持)
    #expect(outcome.reason == .error)
  }

  @Test func currentReasonReflectsRecorded() async {
    let c = ShutdownCoordinator()
    #expect(await c.currentReason() == nil)
    await c.recordSIGINT()
    #expect(await c.currentReason() == .sigint)
  }
}
