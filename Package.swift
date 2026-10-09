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
    ],
    targets: [
        .target(
            name: "CaptionKit",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
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
