import Foundation
import ProcessKit

/// The workspace map: Floorplan's engine, bundled with Meshvy.
///
/// Floorplan splits the work in two. Its scripts do everything mechanical —
/// finding files, parsing imports and endpoints, matching requests across
/// repositories, laying out the map — and need only Node. Claude does what only
/// a reader of the code can: deciding what the parts of the app *are* and
/// describing them plainly. Meshvy runs that second half as a headless
/// `claude -p` in the background (`MapRun`) and opens the map when it is done.
///
/// The engine lives in `Engine/Floorplan` in this repository and is copied into
/// the app as `Contents/Resources/floorplan`. See `Engine/Floorplan/MESHVY.md`.
public enum Floorplan {
    /// The scripts a map thread may run without asking, the same list the
    /// skill's own `allowed-tools` pre-approves.
    public static let scripts = [
        "build.mjs", "describe.mjs", "open.mjs", "plan.mjs",
        "recent.mjs", "refresh.mjs", "scan.mjs", "status.mjs",
    ]

    /// The oldest Node the engine runs on.
    public static let minimumNodeMajor = 18

    /// Title of the browser node that shows the map.
    public static let browserTitle = "Map"

    // MARK: - Finding the engine

    /// The folder holding the engine's `SKILL.md`, or nil if this build has
    /// none.
    ///
    /// In order: `MESHVY_FLOORPLAN_DIR`, for trying a newer engine without a
    /// rebuild; the app bundle; then, for `swift run` from a checkout, the
    /// repository the binary was built in.
    public static func skillDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resources: URL? = Bundle.main.resourceURL,
        executable: URL? = Bundle.main.executableURL
    ) -> String? {
        var candidates: [URL] = []
        if let override = environment["MESHVY_FLOORPLAN_DIR"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources {
            candidates.append(resources.appendingPathComponent("floorplan"))
        }
        if let executable {
            var folder = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(folder.appendingPathComponent("Engine/Floorplan/skills/floorplan"))
                folder = folder.deletingLastPathComponent()
            }
        }
        for candidate in candidates {
            let skill = candidate.appendingPathComponent("SKILL.md").path
            if FileManager.default.fileExists(atPath: skill) {
                return candidate.standardizedFileURL.path
            }
        }
        return nil
    }

    // MARK: - Finding Node

    /// Where `node` usually is on a Mac. An app opened from the Dock gets a
    /// bare PATH, so the places installers put it are looked at directly.
    public static func nodeCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String] {
        var folders: [String] = []
        if let path = environment["PATH"] {
            folders.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        folders.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/.volta/bin",
            home + "/.local/bin",
            home + "/.local/share/mise/shims",
            home + "/.asdf/shims",
            home + "/.nodenv/shims",
            home + "/.fnm/aliases/default/bin",
        ])
        // nvm keeps one folder per version; newest first.
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { compareVersions($0, $1) > 0 }
            folders.append(contentsOf: sorted.map { "\(nvm)/\($0)/bin" })
        }
        var seen = Set<String>()
        return folders
            .map { $0 + "/node" }
            .filter { seen.insert($0).inserted }
    }

    /// The `node` to run the engine with, or nil if there is none.
    ///
    /// Falls back to asking a login shell, whose PATH is the one a terminal
    /// gets. Blocks on that shell, so never from the main thread.
    public static func findNode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        for candidate in nodeCandidates(environment: environment, home: home)
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let result = Shell.run(shell, ["-l", "-c", "command -v node"], cwd: nil, timeout: 10)
        let found = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, found.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: found) else {
            return nil
        }
        return found
    }

    /// An absolute path for `claude`. Meshvy's own lookup can come back as
    /// the bare name, which a terminal resolves but `Process` cannot, so a
    /// bare name is asked of a login shell. Blocks, so never from the main
    /// thread.
    public static func resolveClaude(
        _ preferred: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if preferred.hasPrefix("/") { return preferred }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let result = Shell.run(shell, ["-l", "-c", "command -v claude"], cwd: nil, timeout: 10)
        let found = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, found.hasPrefix("/") else { return nil }
        return found
    }

    /// The major version `node --version` printed, as in `v20.11.1`.
    public static func nodeMajor(fromVersion output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("v") ? trimmed.dropFirst() : Substring(trimmed)
        return digits.split(separator: ".").first.flatMap { Int($0) }
    }

    /// The major version of the `node` at `path`, or nil if it would not say.
    public static func nodeMajor(at path: String) -> Int? {
        let result = Shell.run(path, ["--version"], cwd: nil, timeout: 10)
        guard result.ok else { return nil }
        return nodeMajor(fromVersion: result.stdout)
    }

    // MARK: - The map on disk

    /// Where the engine writes the map: `floorplan/` at the codebase root,
    /// which for a workspace is the workspace folder, outside every
    /// repository.
    public static func mapDirectory(root: String) -> String {
        (root as NSString).appendingPathComponent("floorplan")
    }

    /// Whether a map has been built here, so it can be opened or refreshed
    /// rather than drawn from scratch.
    public static func hasMap(root: String) -> Bool {
        let directory = mapDirectory(root: root) as NSString
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("graph.json"))
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.html"))
    }

    // MARK: - The run that draws it

    /// Tools a map run may use without asking. It runs headless, so anything
    /// not listed here is refused rather than asked about: reading the code,
    /// writing the map's own JSON files, the engine's scripts, and helpers to
    /// describe large workspaces in parallel, as the skill suggests.
    public static func allowedTools(skillDirectory: String) -> [String] {
        ["Read", "Grep", "Glob", "Write", "Edit", "Task", "Agent", "TodoWrite"]
            + scripts.map { "Bash(node \(skillDirectory)/scripts/\($0) *)" }
    }

    /// The prompt for the run that draws or refreshes the map.
    ///
    /// The skill is not installed in Claude Code; the run is pointed at its
    /// `SKILL.md` instead, which already explains how to run it from a folder
    /// (the way Codex does). What differs is that nobody is watching: Meshvy
    /// opens the map itself when the run ends.
    public static func task(skillDirectory: String, root: String, refresh: Bool) -> String {
        var lines: [String] = []
        if refresh {
            lines.append("""
            Update the map of this workspace with Floorplan: re-read what changed \
            since it was last drawn, describe anything new, and mark the recent \
            work.
            """)
        } else {
            lines.append("""
            Draw a map of this workspace with Floorplan: every repository in it, \
            the parts of the app and how they fit together, the screens, the \
            requests between frontend and backend, and the outside services it \
            talks to.
            """)
        }
        lines.append("")
        lines.append("""
        Floorplan comes with Meshvy. Its skill is at `\(skillDirectory)`. Read \
        `\(skillDirectory)/SKILL.md` and follow it, with these differences:

        - `${CLAUDE_SKILL_DIR}` in it means `\(skillDirectory)`.
        - The codebase root is the workspace root, `\(root)`. Every repository \
          is a folder inside it. Run the scripts from there, as \
          `node \(skillDirectory)/scripts/<script>.mjs \(root)`.
        - Nobody can answer questions during this run. Where SKILL.md says to \
          ask, decide yourself and note the assumption in your final report.
        - Write for everyone, in plain language.
        - Stop once build.mjs is clean and the descriptions and recent work are \
          written. Do not run open.mjs: Meshvy opens the map itself.
        - Do not add the CLAUDE.local.md note.
        - End with a short report: the shape of the app in 3 to 5 lines and \
          any high-severity Health items. Never repeat a secret's value.
        """)
        if refresh {
            lines.append("")
            lines.append("A map already exists, so refresh it as SKILL.md describes rather than starting over.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Serving it

    public enum ServeError: Error, Equatable {
        case noEngine
        case noNode
        case nodeTooOld(Int)
        case noMap
        case failed(String)

        /// One line for a banner.
        public var message: String {
            switch self {
            case .noEngine: "This build of Meshvy has no map engine."
            case .noNode: "Maps need Node \(Floorplan.minimumNodeMajor) or newer, and Meshvy could not find node."
            case .nodeTooOld(let major): "Maps need Node \(Floorplan.minimumNodeMajor) or newer; this Mac has Node \(major)."
            case .noMap: "This workspace has no map yet."
            case .failed(let detail): detail
            }
        }
    }

    /// Starts the map's local server, or finds the one already running, and
    /// returns the address to open. The server answers the map's Ask bar
    /// through `claudePath`, and stops itself two hours after the last tab
    /// closes.
    ///
    /// Blocks while the server starts, so never from the main thread.
    public static func serve(
        root: String,
        skillDirectory: String?,
        node: String?,
        claudePath: String?
    ) -> Result<String, ServeError> {
        guard let skillDirectory else { return .failure(.noEngine) }
        guard let node else { return .failure(.noNode) }
        if let major = nodeMajor(at: node), major < minimumNodeMajor {
            return .failure(.nodeTooOld(major))
        }
        guard hasMap(root: root) else { return .failure(.noMap) }

        var arguments = [(skillDirectory as NSString).appendingPathComponent("scripts/open.mjs"), root, "--no-open"]
        if let claudePath, claudePath.hasPrefix("/") {
            arguments.append(contentsOf: ["--claude", claudePath])
        }
        let result = Shell.run(node, arguments, cwd: root, timeout: 40)
        if let url = url(fromOpenOutput: result.stdout) {
            return .success(url)
        }
        let detail = result.stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .failure(.failed(detail ?? (result.timedOut
            ? "The map's server took too long to start."
            : "The map's server did not start.")))
    }

    /// The address on `open.mjs`'s `FLOORPLAN  <url>  (…)` line.
    public static func url(fromOpenOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 2, words[0] == "FLOORPLAN" else { continue }
            let candidate = String(words[1])
            if candidate.hasPrefix("http://127.0.0.1:") || candidate.hasPrefix("http://localhost:") {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Compares dotted versions like `v20.11.1`, numerically.
    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        func parts(_ text: String) -> [Int] {
            let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
            return trimmed.split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = parts(lhs)
        let right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}
