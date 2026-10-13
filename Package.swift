// swift-tools-version:6.0
import Foundation
import PackageDescription

// Meshvy is a modular monolith: one package, many modules, strict edges.
//
// The tiers below are a dependency order, not a filing system. A module may
// only depend on modules above it in this file, which is what keeps the graph
// acyclic — and because every module directory is already shaped like a package
// (`Packages/<Tier>/<Name>/Sources/<Name>/`), promoting one to a standalone
// package later is a change to this manifest and nothing else.
// See Docs/Architecture/0001-modular-monolith.md for why it is not one already.

// MARK: - swift-testing on a toolchain without Xcode
//
// `swift build` here needs only the Command Line Tools, which is deliberate —
// see the README. The CLT does ship swift-testing, but in two places SwiftPM
// does not look: the framework sits under its own Developer/Frameworks, and the
// interop dylib the framework itself loads sits one directory further along in
// Developer/usr/lib. Without the first, `import Testing` is "no such module"
// and no suite in the package is built at all; without the second it builds and
// then dies at launch on `@rpath/lib_TestingInterop.dylib`.
//
// Full Xcode wires both up itself, and so do GitHub's macos runners. These
// arrays are therefore empty whenever Xcode is present — nothing is overridden
// on a normal developer machine or in CI, and `swift test` still works on a
// checkout that only has the CLT.

private let commandLineToolsDeveloper =
    "/Library/Developer/CommandLineTools/Library/Developer"
private let commandLineToolsFrameworks = commandLineToolsDeveloper + "/Frameworks"
private let commandLineToolsLib = commandLineToolsDeveloper + "/usr/lib"

private let needsTestingSearchPath: Bool = {
    let hasXcode = FileManager.default.fileExists(
        atPath: "/Applications/Xcode.app/Contents/Developer")
    let hasCLTTesting = FileManager.default.fileExists(
        atPath: commandLineToolsFrameworks + "/Testing.framework")
    return !hasXcode && hasCLTTesting
}()

private let swiftTestingSearchPath: [SwiftSetting] =
    needsTestingSearchPath ? [.unsafeFlags(["-F", commandLineToolsFrameworks])] : []

private let swiftTestingLinkerPath: [LinkerSetting] =
    needsTestingSearchPath
        ? [.unsafeFlags(["-F", commandLineToolsFrameworks,
                         "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
                         "-Xlinker", "-rpath", "-Xlinker", commandLineToolsLib])]
        : []

let package = Package(
    name: "Meshvy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meshvy", targets: ["Meshvy"])
    ],
    dependencies: [
        // PTY-backed terminal emulator for the canvas terminal nodes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [

        // MARK: - Foundation
        // Pure values and vocabulary. No platform access, no UI, no state.

        .meshvy("MeshvyCore", tier: "Foundation"),
        .meshvy("MeshvyModels", tier: "Foundation", deps: ["MeshvyCore"]),

        // MARK: - Platform
        // One subsystem of the machine each. They know nothing about features.

        .meshvy("ProcessKit", tier: "Platform"),
        .meshvy("FileSystemKit", tier: "Platform"),
        .meshvy("PersistenceKit", tier: "Platform", deps: ["MeshvyCore", "MeshvyModels"]),
        .meshvy("GitKit", tier: "Platform", deps: ["MeshvyModels", "ProcessKit"]),

        // MARK: - Design system
        // Shared visual vocabulary. Depends on no feature and no state, so a
        // view here can be previewed without booting the app.

        // Knows the domain vocabulary (a `Pill` shows a `SessionStatus`) but no
        // feature and no state. MeshvyModels is pure values, so this is safe.
        .meshvy("DesignSystem", deps: ["MeshvyCore", "MeshvyModels"]),

        // Owns the PTY sessions and nothing that draws. `TerminalSurface`, the
        // view that puts one on the canvas, lives in CanvasUI — keeping it here
        // put a SwiftUI view underneath the application state.
        .meshvy(
            "TerminalKit", tier: "Platform",
            deps: ["MeshvyModels", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),

        // MARK: - Capabilities
        // What Meshvy can do, with no opinion about how it looks.

        // AgentKit -> BrowserKit, and not the other way: the agent command line
        // advertises the browser's MCP tools. The reverse edge used to exist too
        // (BrowserBridge reached for AgentBridge's paths) and was a cycle; those
        // paths now live on `Workspace`, which owns the directory.
        .meshvy("AgentKit", tier: "Features",
                deps: ["MeshvyCore", "MeshvyModels", "ProcessKit", "FileSystemKit",
                       "BrowserKit"]),
        .meshvy("SessionKit", tier: "Features",
                deps: ["MeshvyCore", "MeshvyModels", "FileSystemKit", "PersistenceKit"]),
        .meshvy("BrowserKit", tier: "Features",
                deps: ["MeshvyCore", "MeshvyModels"]),
        .meshvy("WorkspaceKit", tier: "Features",
                deps: ["MeshvyModels", "ProcessKit", "GitKit"]),
        .meshvy("UpdateKit", tier: "Features", deps: ["MeshvyCore", "ProcessKit"]),

        // MARK: - Application state
        // The board, and everything the views read. Deliberately has no
        // dependency on any UI module: that is the edge that lets the feature
        // UIs below be separate modules at all.

        .meshvy("AppState", deps: [
            "MeshvyCore", "MeshvyModels", "ProcessKit", "FileSystemKit", "PersistenceKit",
            "GitKit", "TerminalKit", "AgentKit", "SessionKit", "BrowserKit",
            "WorkspaceKit", "UpdateKit",
        ]),

        // MARK: - Feature UI
        // One screen area each. Siblings do not import each other; anything two
        // of them need belongs in DesignSystem.

        .meshvy("AgentsUI", tier: "Features",
                deps: ["AppState", "DesignSystem", "MeshvyModels", "AgentKit"]),
        .meshvy("CanvasUI", tier: "Features",
                deps: ["AppState", "DesignSystem", "MeshvyModels", "TerminalKit",
                       "BrowserKit", "AgentKit", "AgentsUI"]),
        .meshvy("InspectorUI", tier: "Features",
                deps: ["AppState", "DesignSystem", "MeshvyModels", "AgentKit", "SessionKit"]),
        .meshvy("WorkspacesUI", tier: "Features",
                deps: ["AppState", "DesignSystem", "MeshvyModels"]),

        // MARK: - Shell
        // Window, sidebar, palette, status bar: the frame the features sit in.

        .meshvy("AppShell", deps: [
            "AppState", "DesignSystem", "MeshvyModels", "MeshvyCore",
            "CanvasUI", "InspectorUI", "AgentsUI", "WorkspacesUI",
            "AgentKit", "TerminalKit", "UpdateKit",
        ]),

        // MARK: - App
        // Entry point, menus, and the --snapshot/--selftest harnesses that
        // Scripts/make-shots.sh drives against the shipped binary.

        .executableTarget(
            name: "Meshvy",
            dependencies: [
                "AppShell", "AppState", "DesignSystem", "MeshvyCore", "MeshvyModels",
                "CanvasUI", "InspectorUI", "AgentsUI", "WorkspacesUI",
                "AgentKit", "SessionKit", "BrowserKit", "WorkspaceKit",
                "TerminalKit", "GitKit", "PersistenceKit", "ProcessKit", "UpdateKit",
            ],
            path: "Apps/macOS/Sources/Meshvy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // MARK: - Tests
        // One suite per module, so a change to MeshvyCore does not run the
        // canvas tests. Only modules with something worth asserting have one.

        .meshvyTests("MeshvyCore", tier: "Foundation"),
        .meshvyTests("MeshvyModels", tier: "Foundation", deps: ["MeshvyCore"]),
        .meshvyTests("FileSystemKit", tier: "Platform"),
        .meshvyTests("PersistenceKit", tier: "Platform", deps: ["MeshvyCore", "MeshvyModels"]),
        .meshvyTests("ProcessKit", tier: "Platform"),
        .meshvyTests("AgentKit", tier: "Features", deps: ["MeshvyCore", "MeshvyModels"]),
        .meshvyTests("SessionKit", tier: "Features", deps: ["MeshvyCore", "MeshvyModels"]),
        .meshvyTests("GitKit", tier: "Platform", deps: ["MeshvyModels", "ProcessKit"]),
    ]
)

// MARK: - Manifest helpers
//
// Every module is laid out the same way, so the path and the language mode are
// derived rather than repeated 19 times. Repetition in a manifest is where
// drift starts: one target left on a different language mode is invisible in
// review and shows up as a build that only fails in CI.

extension Target {
    /// A library module at `Packages/[<tier>/]<name>/Sources/<name>`.
    static func meshvy(
        _ name: String,
        tier: String? = nil,
        deps: [Target.Dependency] = []
    ) -> Target {
        .target(
            name: name,
            dependencies: deps,
            path: Self.root(name, tier) + "/Sources/\(name)",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    }

    /// The matching suite at `Packages/[<tier>/]<name>/Tests/<name>Tests`.
    static func meshvyTests(
        _ name: String,
        tier: String? = nil,
        deps: [Target.Dependency] = []
    ) -> Target {
        .testTarget(
            name: "\(name)Tests",
            dependencies: [.target(name: name)] + deps,
            path: Self.root(name, tier) + "/Tests/\(name)Tests",
            swiftSettings: [.swiftLanguageMode(.v5)] + swiftTestingSearchPath,
            linkerSettings: swiftTestingLinkerPath
        )
    }

    private static func root(_ name: String, _ tier: String?) -> String {
        tier.map { "Packages/\($0)/\(name)" } ?? "Packages/\(name)"
    }
}
