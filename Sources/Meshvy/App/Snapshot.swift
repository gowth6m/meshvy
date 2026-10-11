import AppKit
import SwiftUI

/// Headless exercise of the workspace flow, for development:
/// `Meshvy --selftest <repoA> <repoB> … [--keep]`. Creates a throwaway
/// workspace, checks every worktree landed on the shared branch, then removes
/// it again unless `--keep` is passed.
@MainActor
enum SelfTest {
    static var keep = false

    static func repoPaths(arguments: [String]) -> [String]? {
        guard let flag = arguments.firstIndex(of: "--selftest") else { return nil }
        let paths = arguments[(flag + 1)...].filter { !$0.hasPrefix("--") }
        return paths.isEmpty ? nil : Array(paths)
    }

    static func run(repoPaths: [String], keep: Bool) {
        Self.keep = keep
        let store = MeshvyStore()
        store.bootstrap()

        let found = store.inspectRepos(at: repoPaths)
        print("inspect: \(found.repos.count) repos, rejected \(found.rejected)")
        guard !found.repos.isEmpty else { exit(1) }

        store.createWorkspace(
            name: "Meshvy Selftest", repos: found.repos, baseRef: nil, branch: "selftest-feature"
        )
        poll(store: store, attempts: 80)
    }

    private static func poll(store: MeshvyStore, attempts: Int) {
        guard let workspace = store.workspaces.first(where: { $0.name == "Meshvy Selftest" }) else {
            guard attempts > 0 else { print("SELFTEST TIMEOUT"); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { poll(store: store, attempts: attempts - 1) }
            }
            return
        }

        print("workspace: \(workspace.name) branch=\(workspace.branch) root=\(workspace.root)")
        var healthy = true
        for repo in workspace.repos {
            let exists = FileManager.default.fileExists(atPath: repo.worktreePath)
            let head = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repo.worktreePath, timeout: 5)
            let branch = head.ok ? (head.lines.first ?? "?") : "n/a"
            print("  - \(repo.name): onDisk=\(exists) branch=\(branch) failure=\(repo.failure ?? "none")")
            if !exists || branch != workspace.branch { healthy = false }
        }
        print("nodes: \(store.graph.nodes.count) edges: \(store.graph.edges.count)")
        print("orchestrator cwd would be: \(workspace.root)")

        if keep {
            print(healthy ? "SELFTEST KEPT" : "SELFTEST FAILED")
            exit(healthy ? 0 : 1)
        }

        store.deleteWorkspace(workspace.id, removeWorktrees: true, force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                let gone = workspace.repos.allSatisfy { !FileManager.default.fileExists(atPath: $0.worktreePath) }
                let forgotten = !store.workspaces.contains { $0.id == workspace.id }
                print("teardown: recordRemoved=\(forgotten) dirsRemoved=\(gone)")
                print(healthy && gone && forgotten ? "SELFTEST OK" : "SELFTEST FAILED")
                exit(healthy && gone && forgotten ? 0 : 1)
            }
        }
    }
}

/// Opens an orchestrator terminal in the active workspace and waits for the
/// agent to register itself. `Meshvy --launchtest`.
@MainActor
enum LaunchTest {
    static func run() {
        let store = MeshvyStore()
        store.bootstrap()
        guard let workspace = store.activeWorkspace else { print("no workspace"); exit(1) }

        print("root: \(workspace.root)")
        print("--- brief ---")
        print(AgentCommand.orchestratorBrief(workspace: workspace))
        print("--- end brief ---")

        store.startOrchestrator()
        guard let node = store.activeWorkspace?.orchestrator else {
            print("LAUNCHTEST FAILED: orchestrator did not start"); exit(1)
        }
        print("orchestrator: \(node.title) cwd=\(node.cwd)")
        // Claude Code asks the user to trust a folder it has not seen before.
        // Answer it the way a person would, then wait for the agent to register.
        answerStartupPrompts(store: store, node: node, attempts: 60, answered: 0)
    }

    /// Clears the prompts Claude Code shows on first run in a new folder, the
    /// way a person at the keyboard would, so the harness reaches the agent.
    private static func answerStartupPrompts(
        store: MeshvyStore, node: TerminalNode, attempts: Int, answered: Int
    ) {
        guard let session = store.terminals.session(for: node.id) else {
            print("LAUNCHTEST FAILED: no session"); exit(1)
        }
        let screen = session.screenText

        if screen.contains("I trust this folder") {
            print("answered: workspace trust")
            session.send("\r")
        } else if screen.contains("Continue without these settings") {
            // This machine's ~/.claude/settings.json is malformed; carry on
            // without it rather than letting the harness stall.
            print("answered: skip malformed settings")
            session.send("3\r")
        } else if answered > 0, screen.contains("│ >") || screen.contains("? for shortcuts") {
            print("agent prompt reached")
            poll(store: store, sessionID: node.sessionID, attempts: 80)
            return
        }

        guard attempts > 0 else {
            poll(store: store, sessionID: node.sessionID, attempts: 60)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                answerStartupPrompts(
                    store: store, node: node,
                    attempts: attempts - 1,
                    answered: answered + (screen.contains("confirm") ? 1 : 0)
                )
            }
        }
    }

    /// Types a task that forces a fan-out, then watches for sub-agent nodes.
    private static func dispatchTask(store: MeshvyStore) {
        guard let terminal = store.activeWorkspace?.orchestrator,
              let session = store.terminals.session(for: terminal.id) else {
            print("LAUNCHTEST FAILED: no orchestrator session"); exit(1)
        }
        let task = "Use the Agent tool to launch one sub-agent per repository "
            + "(api, web, worker). Each one must only reply with the repo name. Run them concurrently."
        print("sending task…")
        session.send(task)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                session.send("\r")
                watchSubAgents(store: store, attempts: 240)
            }
        }
    }

    private static func watchSubAgents(store: MeshvyStore, attempts: Int) {
        let agents = store.subAgents
        if !agents.isEmpty {
            print("sub-agent nodes: \(agents.count)")
            for agent in agents {
                let state = agent.state.isRunning ? "running" : "finished"
                print("  - \(agent.title) [\(agent.kind)] \(state) result=\(agent.result?.prefix(40) ?? "-")")
            }
            if agents.allSatisfy({ !$0.state.isRunning }) {
                print("nodes on board: \(store.graph.nodes.count) edges: \(store.graph.edges.count)")
                print("LAUNCHTEST OK")
                exit(0)
            }
        }
        guard attempts > 0 else {
            print(agents.isEmpty ? "LAUNCHTEST TIMEOUT: no sub-agents seen" : "LAUNCHTEST OK (still running)")
            exit(agents.isEmpty ? 1 : 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { watchSubAgents(store: store, attempts: attempts - 1) }
        }
    }

    private static func poll(store: MeshvyStore, sessionID: String?, attempts: Int) {
        store.refreshLive()
        if let sessionID, let session = store.live[sessionID] {
            print("LIVE: name=\(session.name ?? "-") status=\(session.status.rawValue) pid=\(session.pid)")
            dispatchTask(store: store)
            return
        }
        guard attempts > 0 else {
            print("LAUNCHTEST TIMEOUT")
            if let session = store.terminals.session(for: store.activeWorkspace?.terminals.last?.id ?? UUID()) {
                print("running=\(session.isRunning) exit=\(String(describing: session.exitCode))")
                print("--- terminal screen ---")
                print(session.screenText)
                print("--- end screen ---")
            }
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { poll(store: store, sessionID: sessionID, attempts: attempts - 1) }
        }
    }
}

private extension LaunchTest {}

/// Checks the diff pipeline against a real worktree. `Meshvy --difftest <path>`.
@MainActor
enum DiffTest {
    static func path(arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--difftest"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    static func run(path: String) {
        let git = GitService()
        let changes = git.changes(at: path)
        print("changed files: \(changes.count)")
        for change in changes {
            print("  \(change.kind.letter) \(change.path)  +\(change.additions) -\(change.deletions) staged=\(change.isStaged)")
        }
        guard let first = changes.first(where: { $0.kind != .deleted }) else {
            print("DIFFTEST: nothing to diff"); exit(1)
        }
        let diff = git.diff(at: path, file: first)
        print("\ndiff for \(diff.path): \(diff.lines.count) lines, +\(diff.additions) -\(diff.deletions) binary=\(diff.isBinary)")
        for line in diff.lines.prefix(10) {
            let old = line.oldNumber.map { String($0) } ?? " "
            let new = line.newNumber.map { String($0) } ?? " "
            print(String(format: "  %3@ %3@ | %@ %@", old as NSString, new as NSString, "\(line.kind)", line.text.prefix(50) as NSString))
        }
        let untracked = changes.first { $0.kind == .untracked }
        if let untracked {
            let d = git.diff(at: path, file: untracked)
            print("\nuntracked \(d.path): \(d.lines.count) lines, all-added=\(d.additions)")
        }
        print("DIFFTEST OK")
        exit(0)
    }
}

/// Measures transcript loading on the largest session on disk.
/// `Meshvy --perftest`.
@MainActor
enum PerfTest {
    static func run() {
        let indexer = SessionIndexer()
        let files = indexer.transcriptFiles()
        guard let biggest = files.max(by: { size($0) < size($1) }) else {
            print("no transcripts"); exit(1)
        }
        let summary = indexer.quickSummaries(files: [biggest])[0]

        let clock = Date()
        let transcript = TranscriptLoader().load(summary)
        let loadMs = Date().timeIntervalSince(clock) * 1000
        print("transcript: \(transcript.events.count) events from \(size(biggest) / 1_000_000) MB")
        print("load: \(String(format: "%.0f", loadMs)) ms (once, off the main thread)")
        exit(0)
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Offscreen renderer for development: `Meshvy --snapshot out.png`.
///
/// Renders the real view tree against the real data with `ImageRenderer`, so
/// the UI can be reviewed from a terminal without a visible window.
struct SnapshotRequest {
    var output: URL
    var size: CGSize
    var waitSeconds: Double
    var zoom: Double?
    var zoomToFit: Bool

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return nil }
        output = URL(fileURLWithPath: arguments[flag + 1])

        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        size = CGSize(
            width: value("--width").flatMap(Double.init) ?? 1560,
            height: value("--height").flatMap(Double.init) ?? 960
        )
        waitSeconds = value("--wait").flatMap(Double.init) ?? 6
        zoom = value("--zoom").flatMap(Double.init)
        zoomToFit = zoom == nil && !arguments.contains("--no-fit")
    }
}

@MainActor
enum Snapshot {
    static func run(_ request: SnapshotRequest) {
        let store = MeshvyStore()
        let chromeHeight: CGFloat = 48 + 26 + 2
        let panels: CGFloat = 262 + 430 + 2
        store.viewport.size = CGSize(
            width: max(200, request.size.width - panels),
            height: max(200, request.size.height - chromeHeight)
        )
        store.bootstrap()
        poll(store: store, request: request, deadline: Date().addingTimeInterval(request.waitSeconds))
    }

    private static func poll(store: MeshvyStore, request: SnapshotRequest, deadline: Date) {
        let settled = !store.isIndexing && !store.isLoadingGit && !store.graph.nodes.isEmpty
        guard settled || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { poll(store: store, request: request, deadline: deadline) }
            }
            return
        }

        if store.selection == nil {
            // Prefer a checkout with changes — that is what the panel is for.
            let dirty = store.workspaceChanges.first
            if let dirty {
                store.select(.worktree(dirty.repo.worktreePath))
                store.openDiff(repoPath: dirty.repo.worktreePath, change: dirty.files[0])
            } else if let newest = store.graph.nodes
                .filter({ if case .session = $0.kind { return true } else { return false } })
                .max(by: { $0.sortDate < $1.sortDate }) {
                store.select(newest.id)
            }
        }
        if let zoom = request.zoom {
            store.viewport.scale = CGFloat(zoom)
            if let selected = store.selection, let node = store.graph.node(selected) {
                store.viewport.center = node.frame.center
            } else if let rect = store.graph.contentRect {
                store.viewport.center = rect.center
            }
        } else if request.zoomToFit {
            store.fit()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated { render(store: store, request: request) }
        }
    }

    private static func render(store: MeshvyStore, request: SnapshotRequest) {
        let view = RootView(store: store)
            .frame(width: request.size.width, height: request.size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.meshvySnapshotMode, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: no image\n".utf8)); exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8)); exit(1)
        }
        do {
            try data.write(to: request.output)
            print("snapshot: wrote \(request.output.path) (\(image.width)×\(image.height))")
            print("snapshot: \(store.statusLine)")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8)); exit(1)
        }
        exit(0)
    }
}
