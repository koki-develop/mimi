import Foundation

/// Daemon が stdin から受け取るコマンド。1 行 1 JSON。
/// 拡張は spec §3.1 に従って `type` 文字列のみで判別する (cmd_id 等は付けない)。
public enum DaemonCommand: Sendable, Equatable {
  case start
  case stop
  /// マイク入力を Whisper に通すかどうかを切り替える。
  /// `{"type":"set_mic_enabled","enabled":bool}`。session の有無に関わらず受理する
  /// (daemon-wide フラグ)。
  case setMicEnabled(enabled: Bool)
}

extension DaemonCommand: Decodable {
  private enum CodingKeys: String, CodingKey {
    case type
    case enabled
  }

  private enum Kind: String, Decodable {
    case start
    case stop
    case setMicEnabled = "set_mic_enabled"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .type)
    switch kind {
    case .start: self = .start
    case .stop: self = .stop
    case .setMicEnabled:
      let enabled = try container.decode(Bool.self, forKey: .enabled)
      self = .setMicEnabled(enabled: enabled)
    }
  }
}
