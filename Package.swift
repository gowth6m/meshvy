// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Arcforge",
    platforms: [.macOS(.v14)],
    dependencies: [
        // PTY-backed terminal emulator for the canvas terminal nodes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Arcforge",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Arcforge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
