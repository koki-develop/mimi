import Foundation

/// Daemon が stdin から受け取るコマンド。1 行 1 JSON。
/// 拡張は spec §3.1 に従って `type` 文字列のみで判別する (cmd_id 等は付けない)。
public enum DaemonCommand: Sendable, Equatable {
  case start
  case stop
}

extension DaemonCommand: Decodable {
  private enum CodingKeys: String, CodingKey { case type }

  private enum Kind: String, Decodable {
    case start
    case stop
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .type)
    switch kind {
    case .start: self = .start
    case .stop: self = .stop
    }
  }
}
