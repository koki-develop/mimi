import Foundation
import Testing

@Suite struct InfoPlistTests {
  @Test func declaresExpectedBundleIdentifier() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL =
      repoRoot
      .appendingPathComponent("Sources")
      .appendingPathComponent("transcribe")
      .appendingPathComponent("Info.plist")

    let data = try Data(contentsOf: plistURL)
    let plist =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

    let value = plist?["CFBundleIdentifier"] as? String
    #expect(value == "me.koki.transcribe")
  }

  @Test func declaresSystemAudioCaptureUsageDescription() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL =
      repoRoot
      .appendingPathComponent("Sources")
      .appendingPathComponent("transcribe")
      .appendingPathComponent("Info.plist")

    let data = try Data(contentsOf: plistURL)
    let plist =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

    let value = plist?["NSAudioCaptureUsageDescription"] as? String
    #expect(value == "Required to transcribe system audio output.")
  }

  /// `NSMicrophoneUsageDescription` は first-launch crash safety の必須キー
  /// (両方無いと最初の permission prompt でクラッシュする)。
  /// 値が空文字でもクラッシュは免れるが、空だと審査弾かれるので存在チェック + 非空。
  @Test func declaresMicrophoneUsageDescription() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let plistURL =
      repoRoot
      .appendingPathComponent("Sources")
      .appendingPathComponent("transcribe")
      .appendingPathComponent("Info.plist")

    let data = try Data(contentsOf: plistURL)
    let plist =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]

    let value = try #require(plist?["NSMicrophoneUsageDescription"] as? String)
    #expect(!value.isEmpty)
  }
}
