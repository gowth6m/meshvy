// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Forge",
            path: "Sources/Forge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
