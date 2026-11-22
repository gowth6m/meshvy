import AgentKit
import FloorplanKit
import Foundation
import MeshvyModels

// The workspace map: what the code in this workspace is, drawn by Claude with
// Floorplan's engine and shown on the board.
extension MeshvyStore {
    // MARK: - The map
    //
    // Drawing a map is a headless `claude -p` in the background (`MapRun`),
    // pointed at the bundled engine's SKILL.md. It reads the workspace and
    // writes `floorplan/` at the workspace root, outside every repository; the
    // workspace node shows what it is doing, and the map opens on the board
    // when it is done. Opening a map that already exists needs no Claude at
    // all: the engine's own server is started and a browser node pointed at it.

    /// Whether the active workspace has a map to open.
    public var workspaceHasMap: Bool {
        guard let root = activeWorkspace?.root else { return false }
        return Floorplan.hasMap(root: root)
    }

    /// Whether the active workspace's map server is starting.
    public var isMapOpening: Bool {
        guard let id = activeWorkspace?.id else { return false }
        return mapsOpening.contains(id)
    }

    /// What the active workspace's map run is doing, while one runs.
    public var mapRunProgress: String? {
        guard let id = activeWorkspace?.id else { return nil }
        return mapProgress[id]
    }

    /// Draws the active workspace's map, or brings it up to date if there is
    /// one already.
    public func mapWorkspace() {
        guard let workspace = activeWorkspace else { return }
        let workspaceID = workspace.id
        guard mapRuns[workspaceID] == nil, mapProgress[workspaceID] == nil else { return }
        guard let skill = Floorplan.skillDirectory() else {
            show(.init(kind: .failure, title: "Could not draw the map", detail: Floorplan.ServeError.noEngine.message))
            return
        }
        guard claudeInstalled != false else {
            show(.init(
                kind: .failure,
                title: "Maps need Claude Code",
                detail: "Claude reads the code and describes it. Install Claude Code and sign in once.",
                action: ("Get Claude Code", { [weak self] in self?.openClaudeCodeInstallPage() })
            ))
            return
        }
        let root = workspace.root
        let refresh = Floorplan.hasMap(root: root)
        let claude = AgentCommand.claudePath
        mapProgress[workspaceID] = "Looking for Node"

        // Finding node can mean asking a login shell, so not on the main thread.
        Task.detached(priority: .userInitiated) {
            let node = Floorplan.findNode()
            let major = node.flatMap { Floorplan.nodeMajor(at: $0) }
            let claudePath = Floorplan.resolveClaude(claude)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let claudePath else {
                    self.mapProgress[workspaceID] = nil
                    self.show(.init(
                        kind: .failure,
                        title: "Maps need Claude Code",
                        detail: "Meshvy could not find the claude command.",
                        action: ("Get Claude Code", { [weak self] in self?.openClaudeCodeInstallPage() })
                    ))
                    return
                }
                guard let node else {
                    self.mapProgress[workspaceID] = nil
                    self.showNodeMissing(Floorplan.ServeError.noNode)
                    return
                }
                if let major, major < Floorplan.minimumNodeMajor {
                    self.mapProgress[workspaceID] = nil
                    self.showNodeMissing(Floorplan.ServeError.nodeTooOld(major))
                    return
                }
                self.startMapRun(
                    MapRun(root: root, skillDirectory: skill, claudePath: claudePath, node: node, refresh: refresh),
                    for: workspaceID
                )
            }
        }
    }

    /// Stops the active workspace's map run. What it wrote so far stays.
    public func stopMapRun() {
        guard let id = activeWorkspace?.id else { return }
        mapRuns[id]?.stop()
    }

    private func startMapRun(_ run: MapRun, for workspaceID: UUID) {
        run.onProgress = { [weak self] text in
            self?.mapProgress[workspaceID] = text
        }
        run.onFinish = { [weak self] outcome in
            guard let self else { return }
            self.mapRuns[workspaceID] = nil
            self.mapProgress[workspaceID] = nil
            switch outcome {
            case .finished:
                self.show(.init(kind: .success, title: "The map is ready"))
                if self.activeWorkspace?.id == workspaceID { self.openMap() }
            case .failed(let detail):
                self.show(.init(kind: .failure, title: "Could not draw the map", detail: detail))
            case .stopped:
                self.show(.init(kind: .info, title: "Stopped drawing the map"))
            }
        }
        mapRuns[workspaceID] = run
        mapProgress[workspaceID] = run.progress
        run.start()
    }

    /// Opens the active workspace's map on the board, starting its server if
    /// it is not running. With no map yet, draws one instead.
    public func openMap() {
        guard let workspace = activeWorkspace else { return }
        guard Floorplan.hasMap(root: workspace.root) else {
            mapWorkspace()
            return
        }
        let workspaceID = workspace.id
        guard !mapsOpening.contains(workspaceID) else { return }
        mapsOpening.insert(workspaceID)
        let root = workspace.root
        let claude = AgentCommand.claudePath

        Task.detached(priority: .userInitiated) {
            let result = Floorplan.serve(
                root: root,
                skillDirectory: Floorplan.skillDirectory(),
                node: Floorplan.findNode(),
                claudePath: claude
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.mapsOpening.remove(workspaceID)
                switch result {
                case .success(let url):
                    guard self.activeWorkspace?.id == workspaceID else { return }
                    self.openBrowser(url: url, title: Floorplan.browserTitle)
                case .failure(let error):
                    if error == .noNode {
                        self.showNodeMissing(error)
                    } else if case .nodeTooOld = error {
                        self.showNodeMissing(error)
                    } else {
                        self.show(.init(kind: .failure, title: "Could not open the map", detail: error.message))
                    }
                }
            }
        }
    }

    /// Node is the one thing a map needs that Meshvy does not ship. Say so,
    /// with the way to get it on the banner.
    private func showNodeMissing(_ error: Floorplan.ServeError) {
        show(.init(
            kind: .failure,
            title: "Maps need Node.js",
            detail: error.message,
            action: ("Get Node", { [weak self] in self?.openInBrowser("https://nodejs.org/en/download") })
        ))
    }
}
