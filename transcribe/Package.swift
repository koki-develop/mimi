// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "transcribe",
  platforms: [
    .macOS(.v15)
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
  ],
  targets: [
    .target(
      name: "TranscribeCore",
      dependencies: [
        .product(name: "WhisperKit", package: "argmax-oss-swift")
      ],
      exclude: [
        "CLAUDE.md",
        "Capture/CLAUDE.md",
        "Output/CLAUDE.md",
        "Transcription/CLAUDE.md",
      ]
    ),
    .target(
      name: "TranscribeCLI",
      dependencies: [
        "TranscribeCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "transcribe",
      dependencies: ["TranscribeCLI"],
      exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/transcribe/Info.plist",
        ])
      ]
    ),
    .testTarget(
      name: "TranscribeCoreTests",
      dependencies: ["TranscribeCore"]
    ),
    .testTarget(
      name: "TranscribeCLITests",
      dependencies: ["TranscribeCLI"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
