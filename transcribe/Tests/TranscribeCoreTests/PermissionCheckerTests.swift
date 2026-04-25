import AVFoundation
import Foundation
import Testing

@testable import TranscribeCore

@Suite struct PermissionCheckerTests {
  @Test func authorizedReturnsNil() {
    #expect(PermissionChecker.microphoneError(for: .authorized) == nil)
  }

  @Test func notDeterminedReturnsNil() {
    // .notDetermined は OS 呼び出し側で再判定するので nil を返す。
    #expect(PermissionChecker.microphoneError(for: .notDetermined) == nil)
  }

  @Test func deniedMapsToMicrophoneDenied() {
    #expect(PermissionChecker.microphoneError(for: .denied) == .microphoneDenied)
  }

  @Test func restrictedMapsToMicrophoneRestricted() {
    #expect(PermissionChecker.microphoneError(for: .restricted) == .microphoneRestricted)
  }
}
