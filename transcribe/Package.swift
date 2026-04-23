// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "transcribe",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.18.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
    ],
    targets: [
        .executableTarget(
            name: "transcribe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/transcribe/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "transcribeTests",
            dependencies: ["transcribe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
