// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MimiKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MimiKit", targets: ["MimiKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        // FoundationModelsIntegration requires the macOS 27 SDK.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3"), traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .target(
            name: "MimiKit",
            dependencies: [
                "CEchoCanceller",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            // CEchoCanceller is a static library of C++ code.
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Built by `mise run build:echo-canceller`.
        .binaryTarget(name: "CEchoCanceller", path: "Native/EchoCanceller/build/CEchoCanceller.xcframework"),
        .testTarget(name: "MimiKitTests", dependencies: ["MimiKit"]),
    ]
)
