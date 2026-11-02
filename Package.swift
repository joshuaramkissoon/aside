// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aside",
    platforms: [.macOS("15.2")],
    dependencies: [
        // Auto-update for release builds (scripts/release.sh embeds and signs Sparkle.framework).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "Aside",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Aside",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
