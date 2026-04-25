import Foundation

/// `Transcriber` の動作パラメータ。
/// デフォルト値は WhisperKit + 既存 spec のチューニング結果と同一を維持する
/// (silent default drift を防ぐため `TranscriberConfigurationTests` で sentinel test がある)。
///
/// 不変条件:
/// - `windowSeconds > 0`
/// - `voiceActivityThreshold` は `[0, 1]`
/// - `energyThreshold >= 0`
/// - `language` は空文字でない
public struct TranscriberConfiguration: Sendable, Equatable {
  public let windowSeconds: Double
  public let voiceActivityThreshold: Double
  public let energyThreshold: Float
  public let language: String

  public init(
    windowSeconds: Double = 5.0,
    voiceActivityThreshold: Double = 0.1,
    energyThreshold: Float = 0.005,
    language: String = "ja"
  ) {
    precondition(windowSeconds > 0, "TranscriberConfiguration.windowSeconds must be > 0")
    precondition(
      (0...1).contains(voiceActivityThreshold),
      "TranscriberConfiguration.voiceActivityThreshold must be in [0, 1]")
    precondition(
      energyThreshold >= 0, "TranscriberConfiguration.energyThreshold must be >= 0")
    precondition(!language.isEmpty, "TranscriberConfiguration.language must not be empty")
    self.windowSeconds = windowSeconds
    self.voiceActivityThreshold = voiceActivityThreshold
    self.energyThreshold = energyThreshold
    self.language = language
  }
}
