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
            // Fixtures are declared as a copied resource only. Do not also
            // list them in `exclude`: SwiftPM drops the resource (and the
            // generated Bundle.module accessor) when a path is both excluded
            // and declared, which breaks the bundle-first fixture loader in
            // TestSupport.swift.
            resources: [.copy("Fixtures")]
        ),
        // Live-state probe: `swift run usage-probe chatgpt | claude | both`.
        // Separate from the tests because the suite must stay offline while this
        // one is allowed to read real credentials and hit the network. It is
        // built from the same core, so what it prints is what the panel shows.
        .executableTarget(
            name: "usage-probe",
            dependencies: ["ChatGPTUsageCore"],
            path: "Sources/UsageProbe"
        ),
    ]
)
