import AppKit
import SwiftUI

/// Offscreen renderer for development: `Forge --snapshot out.png`.
///
/// Renders the real view tree against the real `~/.claude` data with
/// `ImageRenderer`, so the UI can be inspected (and diffed) from a terminal
/// without a visible window or screen-recording permission.
struct SnapshotRequest {
    var output: URL
    var size: CGSize
    var waitSeconds: Double
    var selectNewestSession: Bool
    var zoomToFit: Bool
    /// Explicit zoom, centred on the selection. Overrides fit-to-content.
    var zoom: Double?

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return nil }
        output = URL(fileURLWithPath: arguments[flag + 1])

        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let width = value("--width").flatMap(Double.init) ?? 1560
        let height = value("--height").flatMap(Double.init) ?? 960
        size = CGSize(width: width, height: height)
        waitSeconds = value("--wait").flatMap(Double.init) ?? 6
        selectNewestSession = !arguments.contains("--no-select")
        zoom = value("--zoom").flatMap(Double.init)
        zoomToFit = zoom == nil && !arguments.contains("--no-fit")
    }
}

/// Headless end-to-end exercise of the workspace flow, for development:
/// `Forge --selftest <repoA> <repoB> …`. Creates a throwaway workspace, cuts a
/// link across every repo, reports what git actually did, then removes it.
@MainActor
enum SelfTest {
    static var keep = false

    static func request(arguments: [String]) -> [String]? {
        guard let flag = arguments.firstIndex(of: "--selftest") else { return nil }
        let paths = arguments[(flag + 1)...].filter { !$0.hasPrefix("--") }
        return paths.isEmpty ? nil : Array(paths)
    }

    static func run(repoPaths: [String], keep: Bool = false) {
        let store = ForgeStore()
        store.bootstrap()
        Self.keep = keep

        let found = store.inspectRepos(at: repoPaths)
        print("inspect: \(found.repos.count) repos, rejected \(found.rejected)")
        guard !found.repos.isEmpty else { exit(1) }

        let workspace = store.createWorkspace(name: "Forge Selftest", repos: found.repos)
        print("workspace: \(workspace.name) root=\(workspace.worktreeRoot)")

        store.createLink(
            name: "selftest-feature", branch: "selftest-feature", baseRef: nil,
            intent: "Prove that one branch can span every repo in the workspace"
        )
        poll(store: store, workspaceID: workspace.id, attempts: 80)
    }

    private static func poll(store: ForgeStore, workspaceID: UUID, attempts: Int) {
        guard let current = store.workspaces.first(where: { $0.id == workspaceID }) else { exit(1) }
        if let link = current.linkedWorktrees.first {
            print("link: \(link.name) branch=\(link.branch) checkouts=\(link.checkouts.count)")
            var allGood = true
            for checkout in link.checkouts {
                let exists = FileManager.default.fileExists(atPath: checkout.path)
                let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: checkout.path, timeout: 5)
                let head = branch.ok ? (branch.lines.first ?? "?") : "n/a"
                print("  - \(checkout.repoName): onDisk=\(exists) branch=\(head) failure=\(checkout.failure ?? "none")")
                if !exists || head != link.branch { allGood = false }
            }
            print("sections: \(store.sections.map { "\($0.title)(\($0.lanes.count) lanes)" }.joined(separator: ", "))")
            print("nodes: \(store.graph.nodes.count) groups: \(store.graph.groups.count)")

            if Self.keep {
                print("SELFTEST KEPT — workspace left in place for snapshotting")
                exit(allGood ? 0 : 1)
            }
            store.removeLink(link.id, force: true, deleteBranch: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    let after = store.workspaces.first(where: { $0.id == workspaceID })
                    let removed = after?.linkedWorktrees.isEmpty ?? false
                    let gone = link.checkouts.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
                    print("teardown: recordRemoved=\(removed) dirsRemoved=\(gone)")
                    store.deleteWorkspace(workspaceID)
                    print(allGood && removed && gone ? "SELFTEST OK" : "SELFTEST FAILED")
                    exit(allGood && removed && gone ? 0 : 1)
                }
            }
            return
        }
        guard attempts > 0 else { print("SELFTEST TIMEOUT"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { poll(store: store, workspaceID: workspaceID, attempts: attempts - 1) }
        }
    }
}

/// Proves the launch path: starts a real agent in the active workspace's newest
/// link and waits for it to register as live. `Forge --launchtest`.
@MainActor
enum LaunchTest {
    static func run() {
        let store = ForgeStore()
        store.bootstrap()
        guard store.hasWorkspace else { print("no workspace"); exit(1) }

        var request = store.workspaceLaunchTemplate()
        request.role = .orchestrator
        request.prompt = "Reply with exactly: FORGE-LAUNCH-OK. Do not use any tools."
        request.model = "claude-haiku-4-5-20251001"
        request.runsInBackground = true
        print("cwd: \(request.cwd)")
        print("addDirs: \(request.additionalDirs)")
        print("--- brief ---")
        print(AgentLauncher.composePrompt(request))
        print("--- end brief ---")

        store.launchAgent(request)
        poll(store: store, cwd: request.cwd, attempts: 60)
    }

    private static func poll(store: ForgeStore, cwd: String, attempts: Int) {
        store.refreshLive()
        let target = PathIndex.canonicalize(cwd)
        if let session = store.live.values.first(where: {
            $0.cwd.map { PathIndex.canonicalize($0) == target } == true
        }) {
            print("LIVE: name=\(session.name ?? "-") status=\(session.status.rawValue) pid=\(session.pid)")
            print("LAUNCHTEST OK")
            exit(0)
        }
        guard attempts > 0 else { print("LAUNCHTEST TIMEOUT"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { poll(store: store, cwd: cwd, attempts: attempts - 1) }
        }
    }
}

/// Measures the work the inspector used to repeat on every render.
/// `Forge --perftest` — picks the largest transcript on disk.
@MainActor
enum PerfTest {
    static func run() {
        let indexer = SessionIndexer()
        let files = indexer.transcriptFiles()
        guard let biggest = files.max(by: { size($0) < size($1) }) else {
            print("no transcripts"); exit(1)
        }
        let summary = indexer.quickSummaries(files: [biggest])[0]

        var clock = Date()
        let transcript = TranscriptLoader().load(summary)
        let loadMs = Date().timeIntervalSince(clock) * 1000
        print("transcript: \(transcript.events.count) events from \(size(biggest) / 1_000_000) MB")
        print("load: \(String(format: "%.0f", loadMs)) ms (once, off the main thread)")

        // What the filter bar + list used to do on every single render.
        clock = Date()
        for _ in 0..<10 {
            let shown = transcript.events.filter { event in
                switch event.kind {
                case .toolUse, .toolResult: return false
                default: return true
                }
            }
            let tools = transcript.events.filter {
                if case .toolUse = $0.kind { return true }
                if case .toolResult = $0.kind { return true }
                return false
            }.count
            let thinking = transcript.events.filter { $0.kind == .thinking }.count
            let system = transcript.events.filter {
                if case .system = $0.kind { return true }
                if case .attachment = $0.kind { return true }
                return false
            }.count
            _ = (shown.count, tools, thinking, system, shown.isEmpty)
        }
        let beforeMs = Date().timeIntervalSince(clock) * 100
        print("per render BEFORE (recounted every time): \(String(format: "%.2f", beforeMs)) ms")

        clock = Date()
        for _ in 0..<10 {
            _ = (transcript.toolEventCount, transcript.thinkingEventCount, transcript.systemEventCount)
        }
        let afterMs = Date().timeIntervalSince(clock) * 100
        print("per render AFTER  (precomputed):          \(String(format: "%.3f", afterMs)) ms")
        exit(0)
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

@MainActor
enum Snapshot {
    static func run(_ request: SnapshotRequest) {
        let store = ForgeStore()

        // The canvas normally learns its size from a GeometryReader; there is no
        // window here, so derive it from the requested image size.
        let chromeHeight: CGFloat = 46 + 26 + 2
        let panels: CGFloat = 258 + 430 + 2
        store.viewport.size = CGSize(
            width: max(200, request.size.width - panels),
            height: max(200, request.size.height - chromeHeight)
        )
        store.bootstrap()

        let deadline = Date().addingTimeInterval(request.waitSeconds)
        poll(store: store, request: request, deadline: deadline)
    }

    /// Waits for indexing and git discovery, then renders. Polls rather than
    /// awaits so the main run loop keeps servicing the store's own callbacks.
    private static func poll(store: ForgeStore, request: SnapshotRequest, deadline: Date) {
        let settled = !store.isIndexing && !store.isLoadingGit && !store.graph.nodes.isEmpty
        let expired = Date() >= deadline

        guard settled || expired else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { poll(store: store, request: request, deadline: deadline) }
            }
            return
        }

        if request.selectNewestSession, store.selection == nil {
            let newest = store.graph.nodes
                .filter { if case .session = $0.kind { return true } else { return false } }
                .max { $0.sortDate < $1.sortDate }
            if let newest { store.select(newest.id) }
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

        // One more short wait so the transcript load and a layout pass land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated { render(store: store, request: request) }
        }
    }

    private static func render(store: ForgeStore, request: SnapshotRequest) {
        let view = RootView(store: store)
            .frame(width: request.size.width, height: request.size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.forgeSnapshotMode, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: ImageRenderer produced no image\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: request.output)
            print("snapshot: wrote \(request.output.path) (\(image.width)×\(image.height))")
            print("snapshot: \(store.statusLine)")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
