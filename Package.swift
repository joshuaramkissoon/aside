// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aside",
    platforms: [.macOS("15.2")],
    targets: [
        .executableTarget(
            name: "Aside",
            path: "Sources/Aside",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
