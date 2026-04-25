import Foundation
import Testing

@testable import TranscribeCore

@Suite struct PipelineErrorTests {
  @Test func outputAlreadyExistsMapsToCantcreat() {
    #expect(PipelineError.outputAlreadyExists(path: "/tmp/x.jsonl").exitCode == 73)
  }

  @Test func screenRecordingDeniedMapsToNoperm() {
    #expect(PipelineError.permissionDenied(.screenRecordingDenied).exitCode == 77)
  }

  @Test func microphoneDeniedMapsToNoperm() {
    #expect(PipelineError.permissionDenied(.microphoneDenied).exitCode == 77)
  }

  @Test func microphoneRestrictedMapsToNoperm() {
    #expect(PipelineError.permissionDenied(.microphoneRestricted).exitCode == 77)
  }

  @Test func microphoneStatusUnknownMapsToSoftware() {
    #expect(PipelineError.permissionDenied(.microphoneStatusUnknown(rawValue: 99)).exitCode == 70)
  }

  @Test func modelLoadFailedMapsToUnavailable() {
    #expect(PipelineError.modelLoadFailed(reason: "x").exitCode == 69)
  }

  @Test func captureFailedMapsToIoerr() {
    #expect(PipelineError.captureFailed(reason: "x").exitCode == 74)
  }

  @Test func ioFailedMapsToIoerr() {
    #expect(PipelineError.ioFailed(reason: "x").exitCode == 74)
  }

  @Test func unexpectedMapsToSoftware() {
    #expect(PipelineError.unexpected(reason: "x").exitCode == 70)
  }
}
