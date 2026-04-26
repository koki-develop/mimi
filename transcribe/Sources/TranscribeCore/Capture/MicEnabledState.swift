import Foundation

/// `set_mic_enabled` コマンドで切り替える "mic 入力を Whisper に通すか" のフラグ。
/// daemon ライフタイム全体で 1 インスタンス。`AudioOutputTap` (mic) と
/// `TranscribeDaemon` の dispatch ハンドラから共有参照される。
///
/// `StreamErrorBox` と同じく lock-based reference type。`AudioOutputTap.stream(_:didOutputSampleBuffer:of:)`
/// は SC delegate の同期 callback から呼ばれるため、actor 化すると `await` を挟めず実装できない。
/// `Capture/CLAUDE.md` の "@unchecked Sendable rationale" を踏襲。
public final class MicEnabledState: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled: Bool

  public init(initiallyEnabled: Bool = true) {
    self.enabled = initiallyEnabled
  }

  public func isEnabled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }

  /// `internal` にしてるのは、外部 (App ホスト等) から直接書ける状態に
  /// しておくと「daemon コマンドを介さず flag を変える」誤用が起きうるため。
  /// 書き手は同モジュール内 (= `TranscribeDaemon` の dispatch) に限定する。
  /// テストは `@testable import` で internal にアクセス可能。
  func setEnabled(_ value: Bool) {
    lock.lock()
    defer { lock.unlock() }
    enabled = value
  }
}
