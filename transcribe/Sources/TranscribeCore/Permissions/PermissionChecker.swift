import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionError: Error, Equatable {
  case screenRecordingDenied
  case microphoneDenied
  case microphoneRestricted
  case microphoneStatusUnknown(rawValue: Int)
}

public enum PermissionChecker {
  /// OS API を直接叩く production 経路。テストでは `PipelineDependencies.permissionCheck` closure を差し替える。
  public static func ensureAll() async throws {
    try await ensureScreenRecording()
    try await ensureMicrophone()
  }

  static func ensureScreenRecording() async throws {
    if CGPreflightScreenCaptureAccess() { return }
    _ = CGRequestScreenCaptureAccess()
    if CGPreflightScreenCaptureAccess() { return }
    throw PermissionError.screenRecordingDenied
  }

  static func ensureMicrophone() async throws {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
      if await AVCaptureDevice.requestAccess(for: .audio) {
        return
      }
      throw PermissionError.microphoneDenied
    }
    if let error = microphoneError(for: status) {
      throw error
    }
  }

  /// 純粋関数: `AVAuthorizationStatus` を `PermissionError?` に写像する。
  /// `.authorized` / `.notDetermined` (= まだ判定不可、上位で再判定) は nil を返す。
  /// それ以外は対応する error を返す。テストはこの関数に対して 4 ケース全部を網羅する。
  static func microphoneError(for status: AVAuthorizationStatus) -> PermissionError? {
    switch status {
    case .authorized:
      return nil
    case .notDetermined:
      return nil
    case .denied:
      return .microphoneDenied
    case .restricted:
      return .microphoneRestricted
    @unknown default:
      return .microphoneStatusUnknown(rawValue: status.rawValue)
    }
  }
}
