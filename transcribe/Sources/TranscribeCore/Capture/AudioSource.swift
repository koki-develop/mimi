import Foundation

/// 音声入力源を表すタグ。capture 由来の概念のため `Capture/` 配下に配置する。
public enum AudioSource: String, Sendable, Codable {
  case mic
  case system
}
