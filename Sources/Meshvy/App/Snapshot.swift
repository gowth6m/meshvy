import AppKit
import SwiftUI

/// Headless exercise of the workspace flow, for development:
/// `Meshvy --selftest <repoA> <repoB> … [--keep] [--name N] [--branch B]`.
/// Creates a throwaway workspace, checks every worktree landed on the shared
/// branch, then removes it again unless `--keep` is passed.
///
/// `--name` and `--branch` are what `scripts/make-shots.sh` uses: the same
/// build-a-workspace path, kept, so a documentation shot is taken against a
/// board that was made the way a person would make one.
@MainActor
enum SelfTest {
    static var keep = false
    private static var name = "Meshvy Selftest"

    /// Flags that take a value, so the value is not mistaken for a repository.
    private static let valued = ["--name", "--branch"]

    static func repoPaths(arguments: [String]) -> [String]? {
        guard let flag = arguments.firstIndex(of: "--selftest") else { return nil }
        var paths: [String] = []
        var index = flag + 1
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) { index += 2; continue }
            if !argument.hasPrefix("--") { paths.append(argument) }
            index += 1
        }
        return paths.isEmpty ? nil : paths
    }

    static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(repoPaths: [String], keep: Bool, name: String?, branch: String?) {
        Self.keep = keep
        Self.name = name ?? "Meshvy Selftest"
        let store = MeshvyStore.shared
        store.bootstrap()

        let found = store.inspectRepos(at: repoPaths)
        print("inspect: \(found.repos.count) repos, rejected \(found.rejected)")
        guard !found.repos.isEmpty else { exit(1) }

        store.createWorkspace(
            name: Self.name, repos: found.repos, baseRef: nil,
            branch: branch ?? "selftest-feature"
        )
        poll(store: store, attempts: 80)
    }

    private static func poll(store: MeshvyStore, attempts: Int) {
        guard let workspace = store.workspaces.first(where: { $0.name == Self.name }) else {
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
        let store = MeshvyStore.shared
        store.bootstrap()
        guard let workspace = store.activeWorkspace else { print("no workspace"); exit(1) }
        // A harness that fans out three sessions should not do it on the most
        // expensive model available. Set on the catalogue rather than through
        // `selectModel`, so a test run does not rewrite the user's choice.
        store.models.selectedModelID = "claude-haiku-4-5-20251001"

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
        let task = "Run: meshvy spawn api \"reply with the single word API and stop\" "
            + "and then: meshvy spawn web \"reply with the single word WEB and stop\". "
            + "Use the Bash tool. Do not use the Agent tool. Report the two agent ids."
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
        // The bridge is the path that matters now: spawned agents are real
        // terminal nodes, not in-process Agent-tool calls.
        let spawned = store.activeWorkspace?.terminals.filter { $0.bridgeID != nil } ?? []
        if !spawned.isEmpty {
            print("spawned terminal nodes: \(spawned.count)")
            for node in spawned {
                let running = store.terminals.isRunning(node.id)
                print("  - \(node.title) cwd=\(URL(fileURLWithPath: node.cwd).lastPathComponent) running=\(running) session=\(node.sessionID ?? "-")")
            }
            if spawned.count >= 2 {
                print("nodes on board: \(store.graph.nodes.count)")
                // A freshly spawned agent has not reached its first hook yet;
                // give them a moment so the status report means something.
                settleActivity(store: store, nodes: spawned, attempts: 40)
                return
            }
        }
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
            print("LAUNCHTEST TIMEOUT: no agents spawned")
            if let node = store.activeWorkspace?.orchestrator,
               let session = store.terminals.session(for: node.id) {
                print("--- orchestrator screen ---")
                print(session.screenText)
                print("--- end screen ---")
            }
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { watchSubAgents(store: store, attempts: attempts - 1) }
        }
    }

    /// Waits for every spawned agent to report at least once, then reports.
    private static func settleActivity(store: MeshvyStore, nodes: [TerminalNode], attempts: Int) {
        let reported = nodes.allSatisfy { store.activity(for: $0) != nil }
        guard !reported, attempts > 0 else {
            reportActivity(store: store)
            print(reported ? "LAUNCHTEST OK" : "LAUNCHTEST FAILED: spawned agents never reported")
            exit(reported ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { settleActivity(store: store, nodes: nodes, attempts: attempts - 1) }
        }
    }

    /// What the hooks reported for each live terminal. This is the whole status
    /// pipeline running inside the app — settings file, script, watcher, drain —
    /// against sessions in real PTYs.
    private static func reportActivity(store: MeshvyStore) {
        print("--- agent status ---")
        for node in store.activeWorkspace?.allTerminals ?? [] {
            guard let activity = store.activity(for: node) else {
                print("  \(node.title): no hook events")
                if let session = store.terminals.session(for: node.id) {
                    let screen = session.screenText
                        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }.suffix(4)
                    print("      screen: \(screen.joined(separator: " / "))")
                }
                continue
            }
            print("  \(node.title): \(activity.state.rawValue) turns=\(activity.turns) "
                + "tools=\(activity.toolCalls) line=\(activity.line ?? "-")")
        }
        print("waiting on you: \(store.agentsNeedingYou.count)")
        print("--- end agent status ---")
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

/// Exercises the agent bridge without an LLM: writes a spawn request the way
/// the `meshvy` helper would, and checks a real terminal node appears.
/// `Meshvy --bridgetest <repo>`.
@MainActor
enum BridgeTest {
    static func repo(arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--bridgetest"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    static func run(repo: String) {
        let store = MeshvyStore.shared
        store.bootstrap()
        guard let workspace = store.activeWorkspace else { print("no workspace"); exit(1) }
        print("workspace: \(workspace.name) root=\(workspace.root)")

        let id = "test\(Int(Date().timeIntervalSince1970) % 100000)"
        let request = AgentBridge.Request(
            id: id, kind: "spawn", repo: repo,
            task: "reply with the single word BRIDGE and stop"
        )
        let path = AgentBridge.requestsDirectory(for: workspace) + "/\(id).json"
        guard let data = try? JSONEncoder().encode(request) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote request \(id)")

        poll(store: store, id: id, attempts: 60)
    }

    private static func poll(store: MeshvyStore, id: String, attempts: Int) {
        let spawned = store.activeWorkspace?.terminals.filter { $0.bridgeID != nil } ?? []
        if let node = spawned.first(where: { $0.bridgeID == id }) {
            print("terminal node: title=\(node.title)")
            print("  cwd=\(node.cwd)")
            print("  session=\(node.sessionID ?? "-")")
            print("  running=\(store.terminals.isRunning(node.id))")
            let onBoard = store.graph.nodes.contains { $0.id == .terminal(node.id) }
            print("  on canvas=\(onBoard)")
            print(onBoard ? "BRIDGETEST OK" : "BRIDGETEST FAILED: not on canvas")
            exit(onBoard ? 0 : 1)
        }
        guard attempts > 0 else {
            print("BRIDGETEST TIMEOUT: terminals=\(store.activeWorkspace?.terminals.count ?? -1)")
            exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated { poll(store: store, id: id, attempts: attempts - 1) }
        }
    }
}

/// End-to-end check of the status pipeline: install the hooks into a throwaway
/// workspace, run a real `claude` against them, then drain and resolve what
/// came back. `Meshvy --hooktest`.
///
/// This is the one feature that cannot be verified by looking at the board —
/// it depends on the CLI actually invoking our script with the payloads we
/// expect, which only a real session proves.
@MainActor
enum HookTest {
    static func run(keep: Bool = false) {
        let root = NSTemporaryDirectory() + "meshvy-hooktest-\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Hook Test", branch: "hooktest", root: root)

        AgentBridge.install(for: workspace)
        AgentHooks.install(for: workspace)
        let settings = AgentHooks.settingsPath(for: workspace)
        print("settings: \(settings)")
        print("script:   \(AgentHooks.scriptPath(for: workspace))")
        guard FileManager.default.fileExists(atPath: settings) else {
            print("HOOKTEST FAILED: no settings file"); exit(1)
        }

        // A one-shot run that is guaranteed to use a tool, so PreToolUse fires
        // alongside the lifecycle events.
        let result = Shell.run(
            AgentCommand.claudePath,
            [
                "-p", "--settings", settings,
                "--model", "claude-haiku-4-5-20251001",
                "Run the bash command `echo meshvy` and then stop."
            ],
            cwd: root,
            timeout: 180
        )
        print("claude exit=\(result.status) output=\(result.lines.last ?? "-")")

        let events = AgentHooks.drain(for: workspace)
        print("events: \(events.count)")
        for event in events {
            let detail = [event.tool, event.detail, event.message].compactMap { $0 }.joined(separator: " · ")
            print("  \(event.state.rawValue.padded(10))\(detail)")
        }

        // Replay them the way the store does and check the resolved state.
        var activity = AgentActivity(sessionID: events.first?.sessionID ?? "-")
        for event in events {
            activity.state = event.state
            if event.startsTurn { activity.turns += 1 }
            if event.startsTool { activity.toolCalls += 1 }
        }
        print("resolved: state=\(activity.state.rawValue) turns=\(activity.turns) tools=\(activity.toolCalls)")

        let sawTool = events.contains { $0.startsTool }
        let sawTurn = events.contains { $0.startsTurn }
        let ended = activity.state == .ended || activity.state == .done

        // The two `Notification` shapes cannot be provoked from a harness —
        // one needs a permission prompt on screen, the other a minute of
        // silence at the prompt — so they are replayed as payloads instead.
        let notifications = replayNotifications(in: workspace)
        if keep { print("kept: \(root)") } else { try? FileManager.default.removeItem(atPath: root) }

        guard !events.isEmpty, sawTurn, sawTool, ended, notifications else {
            print("HOOKTEST FAILED: turn=\(sawTurn) tool=\(sawTool) ended=\(ended) notifications=\(notifications)")
            exit(1)
        }
        print("HOOKTEST OK")
        exit(0)
    }

    /// Writes the payloads Claude Code sends for the two `Notification` cases
    /// and checks each resolves to the right state.
    private static func replayNotifications(in workspace: Workspace) -> Bool {
        func resolve(_ message: String) -> AgentHooks.Event? {
            let payload: [String: Any] = [
                "event": "Notification",
                "at": Date().timeIntervalSince1970,
                "payload": [
                    "session_id": "replay",
                    "hook_event_name": "Notification",
                    "cwd": workspace.root,
                    "message": message
                ]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            let path = AgentHooks.eventsDirectory(for: workspace) + "/\(UUID().uuidString).json"
            try? data.write(to: URL(fileURLWithPath: path))
            return AgentHooks.drain(for: workspace).first
        }

        let permission = resolve("Claude needs your permission to use Bash")
        let idle = resolve("Claude is waiting for your input")
        print("notification/permission: \(permission?.state.rawValue ?? "-") · \(permission?.message ?? "-")")
        print("notification/idle:       \(idle?.state.rawValue ?? "-")")
        return permission?.state == .blocked && idle?.state == .waiting
    }
}

private extension String {
    /// Left-aligned in a fixed column, for the harness listings.
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}

/// Checks that zooming magnifies a terminal rather than reflowing its grid.
/// `Meshvy --zoomtest`.
@MainActor
enum ZoomTest {
    static func run() {
        let store = MeshvyStore.shared
        store.bootstrap()
        guard store.activeWorkspace != nil else { print("no workspace"); exit(1) }

        guard let node = store.openTerminal(role: .shell) else {
            print("ZOOMTEST FAILED: no terminal"); exit(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated { measure(store: store, node: node) }
        }
    }

    private static func measure(store: MeshvyStore, node: TerminalNode) {
        guard let session = store.terminals.session(for: node.id) else {
            print("ZOOMTEST FAILED: no session"); exit(1)
        }
        let container = TerminalSurface.FlippedContainer()
        container.addSubview(session.surface)

        var results: [(CGFloat, Int, Int, CGFloat)] = []
        for scale in [CGFloat(0.6), 1.0, 2.0] {
            container.scale = scale
            container.frame = CGRect(
                origin: .zero,
                size: CGSize(width: node.size.width * scale, height: node.size.height * scale)
            )
            container.layout()
            let grid = session.grid
            // The container's frame-to-bounds ratio is the magnification.
            let magnification = container.frame.width / max(1, container.bounds.width)
            results.append((scale, grid.cols, grid.rows, magnification))
            print(String(
                format: "zoom %.1fx -> container %.0f/%.0f = %.2fx, terminal frame %.0fpt, grid %dx%d",
                scale, container.frame.width, container.bounds.width, magnification,
                session.surface.frame.width, grid.cols, grid.rows
            ))
        }

        let magnificationsTrack = results.allSatisfy { abs($0.3 - $0.0) < 0.02 }
        let gridStable = Set(results.map { "\($0.1)x\($0.2)" }).count == 1
        print("magnification follows zoom: \(magnificationsTrack)")
        print("grid stays put: \(gridStable)")
        print(magnificationsTrack && gridStable ? "ZOOMTEST OK" : "ZOOMTEST FAILED")
        exit(magnificationsTrack && gridStable ? 0 : 1)
    }
}

/// Exercises the updater against the real GitHub release.
/// `Meshvy --updatetest [--install]`.
@MainActor
enum UpdateTest {
    static func run(install: Bool) {
        print("running version: \(UpdateService.currentVersion ?? "none (dev build)")")

        // Version comparison is the part that silently does the wrong thing.
        let cases: [(String, String, Bool)] = [
            ("0.8.0", "0.7.0", true), ("0.7.0", "0.7.0", false), ("0.7.0", "0.8.0", false),
            ("1.2.10", "1.2.9", true), ("v0.9.0", "0.10.0", false), ("0.10.0", "0.9.0", true)
        ]
        var ok = true
        for (candidate, current, expected) in cases {
            let got = UpdateService.isNewer(candidate, than: current)
            if got != expected { ok = false; print("  FAIL \(candidate) > \(current): \(got)") }
        }
        print("version comparison: \(ok ? "ok" : "FAILED")")
        guard ok else { exit(1) }

        let service = UpdateService()
        service.check(announceNoUpdate: true)
        poll(service: service, install: install, attempts: 40)
    }

    private static func poll(service: UpdateService, install: Bool, attempts: Int) {
        switch service.state {
        case .checking, .idle:
            guard attempts > 0 else { print("UPDATETEST TIMEOUT"); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { poll(service: service, install: install, attempts: attempts - 1) }
            }
        case .upToDate:
            print("state: up to date")
            print("UPDATETEST OK")
            exit(0)
        case .available(let release):
            print("state: update available")
            print("  version: \(release.version)  tag: \(release.tag)")
            print("  zip: \(release.zipURL.lastPathComponent) (\(release.sizeBytes) bytes)")
            print("  checksum asset: \(release.checksumURL != nil)")
            print("  notes: \(release.notes.prefix(60).replacingOccurrences(of: "\n", with: " "))…")
            if install {
                print("installing…")
                service.installAndRestart()
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    MainActor.assumeIsolated { print("install state: \(service.state)"); exit(0) }
                }
            } else {
                print("UPDATETEST OK")
                exit(0)
            }
        case .failed(let message):
            print("state: failed — \(message)")
            print("UPDATETEST FAILED")
            exit(1)
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { poll(service: service, install: install, attempts: attempts - 1) }
            }
        }
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
    /// Start the orchestrator and give it this task before rendering, so a
    /// documentation shot shows a terminal with real output in it.
    var orchestratorTask: String?
    /// Overlays to open before rendering, so the panels that only exist on a
    /// keystroke can be captured too.
    var palette: Bool
    var shortcuts: Bool
    /// Start the orchestrator and wait for it to report, so the status chrome
    /// has something to show.
    var withAgent: Bool
    /// Open a browser node at this URL before rendering, so a board shot has the
    /// running application on it as well as the agents.
    var browserURL: String?
    /// Which node the inspector should be showing. Left alone the shot picks
    /// for itself: the workspace after an agent has run, the browser when the
    /// shot is only about a browser, otherwise a checkout with changes in it.
    var select: Selection?
    /// Hand every free terminal and browser back to the layout before
    /// rendering. An agent lands wherever there was room, so without this the
    /// same shot frames differently every time it is taken.
    var tidy: Bool

    enum Selection: String {
        case workspace, browser, repo
    }

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
        orchestratorTask = value("--orchestrator")
        zoomToFit = zoom == nil && !arguments.contains("--no-fit")
        palette = arguments.contains("--palette")
        shortcuts = arguments.contains("--shortcuts")
        withAgent = arguments.contains("--agent")
        browserURL = value("--browser")
        select = value("--select").flatMap(Selection.init(rawValue:))
        tidy = arguments.contains("--tidy")
    }
}

@MainActor
enum Snapshot {
    private static var pending: SnapshotRequest?

    static func run(_ request: SnapshotRequest) {
        let store = MeshvyStore.shared
        Self.pending = request
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

        // Before the camera is placed, so the board is framed with it on, and
        // before the orchestrator, so the page has the agent's whole run to
        // load.
        if let url = request.browserURL {
            // Point the node the last shot left behind at this URL rather than
            // stacking a second browser beside it.
            if let existing = store.activeWorkspace?.browsers.first {
                store.navigateBrowser(existing.id, to: url)
            } else {
                store.openBrowser(url: url, reveal: false)
            }
        }

        // Bring an orchestrator up when one was asked for; its terminal is the
        // centre of a documentation shot.
        if let task = request.orchestratorTask, !store.isOrchestratorRunning {
            store.startOrchestrator()
            settleOrchestrator(store: store, task: task, request: request, attempts: 360)
            return
        }

        if request.tidy { tidy(store: store) }
        applySelection(store: store, request: request)
        if let zoom = request.zoom {
            store.viewport.scale = CGFloat(zoom)
            if let selected = store.selection, let node = store.boardNode(for: selected) {
                store.viewport.center = node.frame.center
            } else if let rect = store.graph.contentRect {
                store.viewport.center = rect.center
            }
        } else if request.zoomToFit {
            store.fit()
        }

        store.paletteOpen = request.palette
        store.shortcutsOpen = request.shortcuts

        guard request.withAgent else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                MainActor.assumeIsolated { shoot(store: store, request: request) }
            }
            return
        }
        store.startOrchestrator()
        if let id = store.activeWorkspace?.id { store.select(.workspace(id)); store.reveal(.workspace(id)) }
        waitForAgent(store: store, request: request, attempts: 60)
    }

    /// Drops the saved position of every free terminal and browser, which is
    /// how the composer is told to place them itself. An agent spawned mid-run
    /// takes the first gap it finds, so a shot of a delegated run frames
    /// differently every time unless the board is handed back first.
    private static func tidy(store: MeshvyStore) {
        guard let workspace = store.activeWorkspace else { return }
        for terminal in workspace.terminals { store.moveTerminal(terminal.id, to: .zero) }
        for browser in workspace.browsers { store.moveBrowser(browser.id, to: .zero) }
        store.commitTerminalMove()
    }

    /// Puts the inspector on whatever the shot is about: what `--select` asked
    /// for, or the best guess from the rest of the request.
    private static func applySelection(store: MeshvyStore, request: SnapshotRequest) {
        let choice = request.select
            ?? (request.orchestratorTask != nil ? .workspace
                : request.browserURL != nil ? .browser : .repo)

        switch choice {
        case .workspace:
            if let id = store.activeWorkspace?.id { store.select(.workspace(id)) }
        case .browser:
            if let node = store.activeWorkspace?.browsers.first { store.select(.browser(node.id)) }
        case .repo:
            // A checkout with changes in it — that is what the panel is for.
            if let dirty = store.workspaceChanges.first {
                store.select(.worktree(dirty.repo.worktreePath))
                store.openDiff(repoPath: dirty.repo.worktreePath, change: dirty.files[0])
            } else if let newest = store.graph.nodes
                .filter({ if case .session = $0.kind { return true } else { return false } })
                .max(by: { $0.sortDate < $1.sortDate }) {
                store.select(newest.id)
            }
        }
    }

    /// Holds the render until the orchestrator's hooks have said something, so
    /// `--agent` captures a board with live status on it rather than a blank card.
    private static func waitForAgent(store: MeshvyStore, request: SnapshotRequest, attempts: Int) {
        if !store.activity.isEmpty || attempts <= 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                MainActor.assumeIsolated { shoot(store: store, request: request) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                waitForAgent(store: store, request: request, attempts: attempts - 1)
            }
        }
    }

    /// Clears Claude Code's first-run prompts, sends the task, and waits for
    /// the turn to end before handing back to the renderer.
    ///
    /// The end of the turn is taken from the agent's own hooks rather than from
    /// what is on its screen: the CLI's spinner rotates its hint, so "esc to
    /// interrupt" is missing from plenty of frames in which it is still very
    /// much working, and a shot timed on that lands on a half-written answer.
    private static func settleOrchestrator(
        store: MeshvyStore, task: String, request: SnapshotRequest, attempts: Int
    ) {
        guard let node = store.activeWorkspace?.orchestrator,
              let session = store.terminals.session(for: node.id) else {
            finish(store: store, request: request)
            return
        }
        let screen = session.screenText

        if screen.contains("I trust this folder") {
            session.send("\r")
        } else if screen.contains("Continue without these settings") {
            session.send("3\r")
        } else if !Self.sentTask,
                  screen.contains("shift+tab to cycle")
                    || screen.contains("? for shortcuts")
                    || screen.contains("for agents") {
            Self.sentTask = true
            Self.sentAt = Date()
            session.send(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { session.send("\r") }
            }
        } else if Self.sentTask,
                  // Long enough for the first hook event to arrive; before it
                  // does the agent still looks like one sitting at its prompt.
                  Date().timeIntervalSince(Self.sentAt ?? .distantFuture) > 6,
                  let sessionID = node.sessionID,
                  store.activity[sessionID]?.state.isFinished == true {
            // It has answered; let the last frame paint, then shoot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                MainActor.assumeIsolated { finish(store: store, request: request) }
            }
            return
        }

        guard attempts > 0 else { finish(store: store, request: request); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                settleOrchestrator(store: store, task: task, request: request, attempts: attempts - 1)
            }
        }
    }

    private static var sentTask = false
    private static var sentAt: Date?

    private static func finish(store: MeshvyStore, request: SnapshotRequest) {
        if request.tidy { tidy(store: store) }
        // Spawning an agent reveals it, so by the end of a delegated run the
        // inspector is showing whichever one came last. Put it back on whatever
        // the shot is about — by default the workspace's own panel: every
        // repository the agents touched, in one list.
        applySelection(store: store, request: request)
        // Git is polled, and an agent that has just written a file would not be
        // in the panel yet — the same ⌘R a person would reach for.
        store.refreshGitStatus()
        if let zoom = request.zoom {
            // On whatever the shot is about, as the camera does everywhere
            // else; the workspace node only when nothing is selected.
            store.viewport.scale = CGFloat(zoom)
            let centre = store.selection.flatMap { store.boardNode(for: $0) }
                ?? store.activeWorkspace.flatMap { store.graph.node(.workspace($0.id)) }
            store.viewport.center = centre?.frame.center ?? .zero
        } else if request.zoomToFit {
            store.fit()
        }
        awaitGit(store: store, request: request, attempts: 24)
    }

    /// A refresh empties each card's git state while it re-reads it, so a shot
    /// taken during one is of three repositories with nothing to say.
    private static func awaitGit(store: MeshvyStore, request: SnapshotRequest, attempts: Int) {
        guard store.isLoadingGit, attempts > 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated { shoot(store: store, request: request) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                awaitGit(store: store, request: request, attempts: attempts - 1)
            }
        }
    }

    /// Fills in every browser's still before the render, because the capture
    /// needs a window and the `ImageRenderer` pass has none.
    private static func shoot(store: MeshvyStore, request: SnapshotRequest) {
        let nodes = store.activeWorkspace?.browsers ?? []
        guard !nodes.isEmpty else { render(store: store, request: request); return }
        Task { @MainActor in
            for node in nodes {
                guard let session = store.ensureBrowserRunning(node.id) else { continue }
                // The card's body, not the card: the header and address bar
                // are drawn by SwiftUI above the page.
                await session.capturePoster(
                    size: CGSize(width: node.size.width, height: max(120, node.size.height - 60))
                )
            }
            render(store: store, request: request)
        }
    }

    private static func render(store: MeshvyStore, request: SnapshotRequest) {
        // A documentation shot is of the whole app, panels and all, whatever
        // the board was left in.
        store.sidebarVisible = true
        store.inspectorVisible = true
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
