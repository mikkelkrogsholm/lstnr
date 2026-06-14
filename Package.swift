// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vara",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VaraCore", targets: ["VaraCore"]),
        .executable(name: "vara", targets: ["VaraCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
        // On-device Whisper via Core ML + Apple Neural Engine. No Python, no key —
        // the CoreML model is fetched from HuggingFace on first use. See WhisperKitBackend.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "VaraCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/VaraCore"
        ),
        .executableTarget(
            name: "VaraCLI",
            dependencies: [
                "VaraCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/VaraCLI"
        ),
        .testTarget(
            name: "VaraCoreTests",
            dependencies: ["VaraCore"],
            path: "Tests/VaraCoreTests"
        ),
    ]
)
