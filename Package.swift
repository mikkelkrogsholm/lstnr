// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lstnr",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LstnrCore", targets: ["LstnrCore"]),
        .executable(name: "lstnr", targets: ["LstnrCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
        // On-device Whisper via Core ML + Apple Neural Engine. No Python, no key —
        // the CoreML model is fetched from HuggingFace on first use. See WhisperKitBackend.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "LstnrCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/LstnrCore"
        ),
        .executableTarget(
            name: "LstnrCLI",
            dependencies: [
                "LstnrCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/LstnrCLI"
        ),
        .testTarget(
            name: "LstnrCoreTests",
            dependencies: ["LstnrCore"],
            path: "Tests/LstnrCoreTests"
        ),
    ]
)
