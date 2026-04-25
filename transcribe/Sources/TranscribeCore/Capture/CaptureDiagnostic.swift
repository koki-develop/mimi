import Foundation

/// `AudioCapture` 層が `Pipeline` 側に伝える非致命的な情報。
/// `.warning` は JSONL の `warning` event に変換され、`.status` は stderr のみへ転送される。
/// 同期 yield のチャネルなので、capture 側に fire-and-forget `Task { reporter.* }` を持たずに済む。
public enum CaptureDiagnostic: Sendable {
  /// converter 失敗等の警告。`source` は由来不明な場合に nil。
  case warning(source: AudioSource?, message: String)
  /// verbose mode 時の debug ステータスメッセージ。
  case status(message: String)
}
