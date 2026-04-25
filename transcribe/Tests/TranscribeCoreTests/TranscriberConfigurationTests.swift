import Foundation
import Testing

@testable import TranscribeCore

/// `TranscriberConfiguration` のデフォルト値を pin する sentinel test。
/// 本テストは tautological に見えるが、silent default drift (パラメータが気付かないうちに
/// 変わる) を catch するための防波堤として明示的に維持する。
@Suite struct TranscriberConfigurationTests {
  @Test func defaultsMatchExpectedValues() {
    let cfg = TranscriberConfiguration()
    #expect(cfg.windowSeconds == 5.0)
    #expect(cfg.voiceActivityThreshold == 0.1)
    #expect(cfg.energyThreshold == Float(0.005))
    #expect(cfg.language == "ja")
  }

  @Test func explicitOverrides() {
    let cfg = TranscriberConfiguration(
      windowSeconds: 3.0,
      voiceActivityThreshold: 0.2,
      energyThreshold: 0.01,
      language: "en"
    )
    #expect(cfg.windowSeconds == 3.0)
    #expect(cfg.voiceActivityThreshold == 0.2)
    #expect(cfg.energyThreshold == Float(0.01))
    #expect(cfg.language == "en")
  }
}
