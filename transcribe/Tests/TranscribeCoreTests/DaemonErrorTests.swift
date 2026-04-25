import Foundation
import Testing

@testable import TranscribeCore

@Suite struct DaemonErrorTests {
  @Test func screenRecordingDeniedMapsToNoperm() {
    #expect(DaemonError.permissionDenied(.screenRecordingDenied).exitCode == 77)
  }

  @Test func microphoneDeniedMapsToNoperm() {
    #expect(DaemonError.permissionDenied(.microphoneDenied).exitCode == 77)
  }

  @Test func microphoneRestrictedMapsToNoperm() {
    #expect(DaemonError.permissionDenied(.microphoneRestricted).exitCode == 77)
  }

  @Test func microphoneStatusUnknownMapsToSoftware() {
    #expect(DaemonError.permissionDenied(.microphoneStatusUnknown(rawValue: 99)).exitCode == 70)
  }

  @Test func modelLoadFailedMapsToUnavailable() {
    #expect(DaemonError.modelLoadFailed(reason: "x").exitCode == 69)
  }

  @Test func captureFailedMapsToIoerr() {
    #expect(DaemonError.captureFailed(reason: "x").exitCode == 74)
  }

  @Test func ioFailedMapsToIoerr() {
    #expect(DaemonError.ioFailed(reason: "x").exitCode == 74)
  }

  @Test func unexpectedMapsToSoftware() {
    #expect(DaemonError.unexpected(reason: "x").exitCode == 70)
  }
}
