// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveCaption",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "CaptionKit", targets: ["CaptionKit"]),
        .executable(name: "caption-harness", targets: ["CaptionHarness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Pinned to an exact revision rather than a version range: every diarization number in
        // ENGINES.md was measured against this commit, and FluidAudio ships model-download URLs
        // and CoreML shapes that a moving dependency would silently change under the measurements.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "fc8c3e4f5103bf63a242453566525272e143a054"
        ),
    ],
    targets: [
        .target(
            name: "CaptionKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "CaptionHarness",
            dependencies: [
                "CaptionKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CaptionKitTests",
            dependencies: ["CaptionKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
