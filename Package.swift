// swift-tools-version: 5.9
import PackageDescription

// Package manifest exists so `swift test` can run the core target and its test
// suite without Xcode. The app target (Sources/App, Sources/UI) is AppKit and
// SwiftUI only and is built by the Xcode project, not by this package.
let package = Package(
    name: "ChatGPTUsageTracker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ChatGPTUsageCore",
            path: "Sources/ChatGPTUsageCore"
        ),
        .testTarget(
            name: "ChatGPTUsageCoreTests",
            dependencies: ["ChatGPTUsageCore"],
            path: "Tests/ChatGPTUsageCoreTests",
            exclude: ["Fixtures"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
