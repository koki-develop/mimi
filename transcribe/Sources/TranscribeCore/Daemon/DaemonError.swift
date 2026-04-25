import Foundation

/// `TranscribeDaemon.run` (および移行期の `Pipeline.run`) が外に投げる統括エラー。
/// CLI 層 (`TranscribeCommand`) が `ExitCode` にマッピングする。
public enum DaemonError: Error, Equatable {
  case outputAlreadyExists(path: String)
  case permissionDenied(PermissionError)
  case modelLoadFailed(reason: String)
  case captureFailed(reason: String)
  case ioFailed(reason: String)
  case unexpected(reason: String)
}

extension DaemonError {
  /// `sysexits.h` 由来の exit code に変換する。
  /// ・73 EX_CANTCREAT  - output 既存
  /// ・77 EX_NOPERM     - permission 拒否系 (denied / restricted)
  /// ・69 EX_UNAVAILABLE - model load 失敗
  /// ・74 EX_IOERR      - I/O 系 (capture / writer)
  /// ・70 EX_SOFTWARE   - その他 (microphone authorization status unknown 含む)
  public var exitCode: Int32 {
    switch self {
    case .outputAlreadyExists:
      return 73
    case .permissionDenied(.screenRecordingDenied),
      .permissionDenied(.microphoneDenied),
      .permissionDenied(.microphoneRestricted):
      return 77
    case .permissionDenied(.microphoneStatusUnknown):
      return 70
    case .modelLoadFailed:
      return 69
    case .captureFailed, .ioFailed:
      return 74
    case .unexpected:
      return 70
    }
  }
}
