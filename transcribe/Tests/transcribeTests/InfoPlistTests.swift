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
}
