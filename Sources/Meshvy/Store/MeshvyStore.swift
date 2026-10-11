import AppKit
import Observation
import SwiftUI

/// Everything the board renders from, plus the refresh machinery.
///
/// A workspace is a set of worktrees — one per repository, all on the same
/// branch, under `~/.forge/<slug>/`. That folder is the parent an orchestrator
/// works from. A fresh install has no workspaces, so the board starts empty.
@MainActor
@Observable
final class MeshvyStore {
    /// One store per process. The SwiftUI scene and the headless harnesses both
    /// reach for this — two instances would mean two sets of timers, two
    /// filesystem watchers, and two readers racing for the same agent-bridge
    /// request files.
    static let shared = MeshvyStore()

    // MARK: Workspaces
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == activeWorkspaceID }
    }

    var hasWorkspace: Bool { activeWorkspace != nil }

    // MARK: Data
    private(set) var allSessions: [SessionSummary] = []
    /// Live git state for the active workspace's checkouts, keyed by path.
    private(set) var worktrees: [String: Worktree] = [:]
    private(set) var live: [String: LiveSession] = [:]
    /// Sub-agents the orchestrator has dispatched, read from its transcript.
    private(set) var subAgents: [SubAgent] = []
    /// What each agent is doing, keyed by session id. Fed by the agent's own
    /// hooks — see `AgentHooks`.
    private(set) var activity: [String: AgentActivity] = [:]
    /// Terminals that changed state while you were looking elsewhere.
    private(set) var unread: Set<UUID> = []
    /// Changed files per checkout, keyed by worktree path.
    private(set) var changes: [String: [FileChange]] = [:]
    /// The file currently open in the diff viewer.
    private(set) var openFile: (repoPath: String, change: FileChange)?
    private(set) var openDiff: FileDiff?
    private(set) var isLoadingDiff = false
    private(set) var graph = CanvasGraph()

    // MARK: View state
    var viewport = Viewport()
    var selection: NodeID?
    var searchQuery = "" { didSet { recomputeMatches() } }
    private(set) var matchingNodes: Set<String> = []

    var showEndedSessions = true { didSet { rebuild(); persistLayout() } }
    var invertScroll = false { didSet { persistLayout() } }
    var inspectorVisible = true
    var sidebarVisible = true
    var sidebarWidth: Double = 262
    var inspectorWidth: Double = 430

    /// Open state of the ⌘K palette.
    var paletteOpen = false
    var shortcutsOpen = false

    /// Permission mode new agents start in. Only the starting mode — ⇧⇥ still
    /// cycles it live inside the session, exactly as it does in Claude Code.
    var permissionMode = PermissionMode.acceptEdits { didSet { persistLayout() } }

    /// Terminal the pointer is over, and the one it has dwelled on long enough
    /// to be handed the scroll wheel. Nil means the canvas keeps panning.
    private(set) var hoveredTerminal: UUID?
    private(set) var armedTerminal: UUID?
    private var armTask: Task<Void, Never>?

    /// How long the pointer has to rest on a terminal before it takes the
    /// wheel. Long enough that flicking across the board never scrolls one by
    /// accident, short enough not to feel like waiting.
    private static let armDelay = Duration.milliseconds(500)

    private(set) var isIndexing = false
    private(set) var isLoadingGit = false
    private(set) var isWorking = false
    private(set) var statusLine = "No workspace"
    private(set) var banner: Banner?

    struct Banner: Identifiable {
        enum Kind { case info, success, failure }
        var id = UUID()
        var kind: Kind
        var title: String
        var detail: String?
    }

    // MARK: Transcript reader
    private(set) var transcript: Transcript?
    private(set) var transcriptSessionID: String?
    private(set) var isLoadingTranscript = false

    // MARK: Collaborators
    let terminals = TerminalRegistry()
    let models = ModelCatalog()
    let updates = UpdateService()
    let notifier = Notifier()
    private let indexer = SessionIndexer()
    private let liveMonitor = LiveSessionMonitor()
    private let git = GitService()
    private let builder = WorkspaceBuilder()
    private let composer = BoardComposer()
    private let subAgentTracker = SubAgentTracker()
    private let workspaceStore = WorkspaceStore()
    private let layoutStore = FileStore<SavedLayout>(filename: "layout.json")
    private let transcriptLoader = TranscriptLoader()

    private var saved = SavedLayout()
    private var pinned: [String: CGPoint] = [:]
    private var watchers: [DirectoryWatcher] = []
    private var bridgeWatcher: DirectoryWatcher?
    private var hookWatcher: DirectoryWatcher?
    private var liveTimer: Timer?
    private var gitTimer: Timer?
    private var hasFitInitially = false
    private var sessionIndexByID: [String: Int] = [:]
    private var hasBootstrapped = false

    // MARK: - Lifecycle

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        loadSavedLayout()
        let document = workspaceStore.load()
        // A terminal's process does not survive a quit, and an empty shell of
        // one is just clutter — start each launch with a clean board.
        workspaces = document.workspaces.map { workspace in
            var copy = workspace
            copy.terminals = []
            copy.orchestrator = nil
            return copy
        }
        activeWorkspaceID = document.activeWorkspaceID ?? document.workspaces.first?.id
        if workspaces != document.workspaces { persistWorkspaces() }

        refreshLive(rebuildGraph: false)
        startWatching()
        startTimers()
        models.refresh()
        // Quietly, on launch: only speaks up when there is something to take.
        updates.check()

        guard hasWorkspace else {
            statusLine = "No workspace — create one to get started"
            return
        }
        loadActiveWorkspace()
    }

    private func loadSavedLayout() {
        guard let stored = layoutStore.load() else { return }
        saved = stored
        pinned = stored.pinned.mapValues { CGPoint(x: $0.x, y: $0.y) }
        showEndedSessions = stored.showEndedSessions
        invertScroll = stored.invertScroll
        sidebarWidth = min(max(stored.sidebarWidth, 200), 520)
        inspectorWidth = min(max(stored.inspectorWidth, 320), 900)
        permissionMode = PermissionMode(rawValue: stored.permissionMode) ?? .acceptEdits
        notifier.isEnabled = stored.notificationsEnabled
        viewport.center = CGPoint(x: stored.cameraX, y: stored.cameraY)
        viewport.scale = max(Viewport.minScale, min(Viewport.maxScale, stored.scale))
        hasFitInitially = stored.scale > 0
    }

    private func loadActiveWorkspace() {
        guard let workspace = activeWorkspace else { return }
        let files = indexer.transcriptFiles()
        allSessions = indexer.quickSummaries(files: files).sorted { $0.lastActivityAt > $1.lastActivityAt }
        sessionIndexByID = Dictionary(
            allSessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
        rebuild()
        startIndexing(files: files)
        refreshGitStatus()
        AgentHooks.reset(for: workspace)
        activity = [:]
        startBridge(for: workspace)
    }

    // MARK: - Creating a workspace

    /// Resolves picked folders into repositories we can cut worktrees from.
    func inspectRepos(at paths: [String]) -> (repos: [WorkspaceRepo], rejected: [String]) {
        var repos: [WorkspaceRepo] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let repo = builder.inspectRepo(at: path) else {
                rejected.append(URL(fileURLWithPath: path).lastPathComponent)
                continue
            }
            guard seen.insert(repo.id).inserted else { continue }
            repos.append(repo)
        }
        return (repos, rejected)
    }

    /// Branches offered as a base when creating a workspace.
    func branches(for repos: [WorkspaceRepo]) -> [String] {
        builder.branches(for: repos)
    }

    /// Creates the workspace and its worktrees in one step: every repository
    /// gets a checkout of the same new branch under `~/.forge/<slug>/`.
    func createWorkspace(name: String, repos: [WorkspaceRepo], baseRef: String?, branch: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Workspace" : trimmed
        let branchName = (branch?.isEmpty == false ? branch! : Workspace.slug(resolved))
        let builder = self.builder

        isWorking = true
        show(.init(kind: .info, title: "Creating worktrees in \(repos.count) repos…", detail: nil))

        Task.detached(priority: .userInitiated) {
            let workspace = builder.build(name: resolved, branch: branchName, baseRef: baseRef, repos: repos)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                self.workspaces.append(workspace)
                self.activeWorkspaceID = workspace.id
                self.persistWorkspaces()
                self.hasFitInitially = false
                self.loadActiveWorkspace()

                let failures = workspace.repos.compactMap { repo in
                    repo.failure.map { "\(repo.name): \($0)" }
                }
                if failures.isEmpty {
                    self.show(.init(
                        kind: .success,
                        title: "“\(resolved)” ready — \(workspace.readyRepos.count) worktrees on \(branchName)",
                        detail: workspace.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    ))
                } else {
                    self.show(.init(
                        kind: .failure,
                        title: "\(workspace.readyRepos.count) of \(workspace.repos.count) worktrees created",
                        detail: failures.joined(separator: "\n")
                    ))
                }
            }
        }
    }

    func addRepos(_ repos: [WorkspaceRepo]) {
        guard let workspace = activeWorkspace else { return }
        let builder = self.builder
        isWorking = true

        Task.detached(priority: .userInitiated) {
            let updated = builder.extend(workspace, with: repos)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                self.update(updated)
                self.refreshGitStatus()
                self.show(.init(kind: .success, title: "Added \(repos.count) to “\(workspace.name)”", detail: nil))
            }
        }
    }

    func cloneRepos(_ references: [String], thenAddToActive: Bool) {
        let builder = self.builder
        isWorking = true
        show(.init(kind: .info, title: "Cloning \(references.count)…", detail: nil))

        Task.detached(priority: .userInitiated) {
            let outcomes = references.map { ($0, builder.clone($0)) }
            let cloned: [WorkspaceRepo] = outcomes.compactMap {
                if case .cloned(let repo) = $0.1 { return repo } else { return nil }
            }
            let failures: [String] = outcomes.compactMap {
                if case .failed(let message) = $0.1 { return "\($0.0): \(message)" } else { return nil }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if !cloned.isEmpty, thenAddToActive { self.addRepos(cloned) }
                if !failures.isEmpty {
                    self.show(.init(kind: .failure, title: "Clone failed", detail: failures.joined(separator: "\n")))
                }
            }
        }
    }

    func activate(_ id: UUID) {
        guard id != activeWorkspaceID else { return }
        activeWorkspaceID = id
        selection = nil
        transcript = nil
        transcriptSessionID = nil
        worktrees = [:]
        activity = [:]
        unread = []
        notifier.badge(0)
        hasFitInitially = false
        persistWorkspaces()
        loadActiveWorkspace()
    }

    /// Forgets the workspace. `removeWorktrees` also tears the checkouts off disk.
    func deleteWorkspace(_ id: UUID, removeWorktrees: Bool, force: Bool) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        for terminal in workspace.allTerminals { terminals.discard(terminal.id) }

        guard removeWorktrees else {
            forget(id)
            return
        }

        let builder = self.builder
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let failures = builder.tearDown(workspace, force: force, deleteBranch: force)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if failures.isEmpty {
                    self.forget(id)
                    self.show(.init(kind: .success, title: "Removed “\(workspace.name)”", detail: nil))
                } else {
                    self.show(.init(
                        kind: .failure,
                        title: "Some worktrees were kept",
                        detail: failures.joined(separator: "\n")
                            + "\n\nUse “Delete and discard changes” to force removal."
                    ))
                }
            }
        }
    }

    private func forget(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id {
            activeWorkspaceID = workspaces.first?.id
            worktrees = [:]
            hasFitInitially = false
        }
        persistWorkspaces()
        if hasWorkspace { loadActiveWorkspace() } else { graph = CanvasGraph() }
        statusLine = hasWorkspace ? summaryLine() : "No workspace — create one to get started"
    }

    func removeRepo(_ repoID: String) {
        guard var workspace = activeWorkspace else { return }
        workspace.repos.removeAll { $0.id == repoID }
        workspace.terminals.removeAll { $0.repoID == repoID }
        update(workspace)
    }

    private func update(_ workspace: Workspace) {
        guard let position = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[position] = workspace
        persistWorkspaces()
        rebuild()
    }

    private func persistWorkspaces() {
        workspaceStore.save(.init(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID))
    }

    // MARK: - Terminals

    // MARK: - Agent bridge
    //
    // Claude's Agent tool runs sub-agents in-process, so they have no terminal
    // to show. Instead the orchestrator is told to delegate with the `meshvy`
    // helper, which drops a request here and gets a real agent back — its own
    // process, its own PTY, its own node on the canvas.

    private func startBridge(for workspace: Workspace) {
        AgentBridge.install(for: workspace)
        AgentHooks.install(for: workspace)
        bridgeWatcher = DirectoryWatcher(
            paths: [AgentBridge.requestsDirectory(for: workspace)],
            debounce: 0.2
        ) { [weak self] in
            Task { @MainActor in self?.drainBridge() }
        }
        // Status should feel immediate — a badge that lags a second behind the
        // agent is worse than no badge.
        hookWatcher = DirectoryWatcher(
            paths: [AgentHooks.eventsDirectory(for: workspace)],
            debounce: 0.1
        ) { [weak self] in
            Task { @MainActor in self?.drainHooks() }
        }
        drainBridge()
    }

    /// Handles everything the helper has asked for since the last pass.
    private func drainBridge() {
        guard let workspace = activeWorkspace else { return }
        for (url, request) in AgentBridge.pendingRequests(for: workspace) {
            // Remove first: a request that throws must not be retried forever.
            try? FileManager.default.removeItem(at: url)
            switch request.kind {
            case "spawn": handleSpawn(request, in: workspace)
            case "send": handleSend(request)
            default: continue
            }
        }
    }

    private func handleSpawn(_ request: AgentBridge.Request, in workspace: Workspace) {
        guard let repoName = request.repo,
              let repo = workspace.repos.first(where: { $0.name == repoName }) else {
            show(.init(kind: .failure, title: "Agent asked for an unknown repo", detail: request.repo))
            return
        }
        guard let node = openTerminal(
            role: .repo,
            repoID: repo.id,
            openingTask: request.task,
            bridgeID: request.id
        ) else { return }

        AgentBridge.record(
            .init(
                id: request.id,
                sessionId: node.sessionID,
                repo: repo.name,
                cwd: node.cwd,
                transcriptHint: node.sessionID,
                startedAt: Date().timeIntervalSince1970
            ),
            in: workspace
        )
        show(.init(
            kind: .success,
            title: "Orchestrator started an agent in \(repo.name)",
            detail: request.task
        ))
    }

    // MARK: - Agent status
    //
    // Every session Meshvy starts is handed a settings file whose hooks report
    // what the agent is doing. Nothing here parses terminal output.

    /// Applies everything the hooks have reported since the last pass.
    private func drainHooks() {
        guard let workspace = activeWorkspace else { return }
        let before = activity
        checkStartupPrompts()
        for event in AgentHooks.drain(for: workspace) { apply(event) }
        guard activity != before else { return }

        notifier.badge(agentsNeedingYou.count)
        statusLine = summaryLine()
        AgentBridge.publishStatus(statusRows(), in: workspace)
    }

    /// What every agent is doing, in the shape `meshvy status` prints.
    private func statusRows() -> [AgentBridge.StatusRow] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.allTerminals.compactMap { node in
            guard let record = activity(for: node) else { return nil }
            return AgentBridge.StatusRow(
                id: node.bridgeID,
                title: node.title,
                repo: workspace.repos.first { $0.id == node.repoID }?.name,
                state: record.state.rawValue,
                line: record.line
            )
        }
    }

    private func apply(_ event: AgentHooks.Event) {
        var record = activity[event.sessionID] ?? AgentActivity(sessionID: event.sessionID)
        let previous = record.state

        record.state = event.state
        record.updatedAt = event.at
        if event.startsTurn { record.turns += 1 }
        if event.startsTool { record.toolCalls += 1 }
        switch event.state {
        case .working:
            // A turn starting clears the previous turn's tool and reply.
            if event.startsTurn { record.tool = nil; record.detail = nil }
            if event.startsTool { record.tool = event.tool; record.detail = event.detail }
            record.message = nil
        case .blocked, .done:
            record.message = event.message
            record.tool = nil
            record.detail = nil
        case .waiting, .ended:
            record.tool = nil
            record.detail = nil
            record.message = event.message
        }
        activity[event.sessionID] = record

        guard previous != record.state,
              let node = terminalNode(forSession: event.sessionID) else { return }
        announce(record, node: node)
    }

    /// A question appearing, or a turn ending, is the moment worth a nudge —
    /// and only if you are not already looking at that node.
    private func announce(_ record: AgentActivity, node: TerminalNode) {
        let worthTelling = record.state == .blocked || record.state == .done
        let id = canvasID(for: node)
        guard worthTelling, selection != id else { return }
        unread.insert(node.id)

        guard !NSApp.isActive else { return }
        notifier.post(
            title: record.state == .blocked
                ? "\(node.title) needs you"
                : "\(node.title) finished",
            body: record.message,
            node: id
        )
    }

    /// Flags an agent stopped on a dialog that runs before its session exists,
    /// which no hook can report. Only ever fills a gap: a session that has
    /// reported once is left to its hooks forever.
    private func checkStartupPrompts() {
        guard let workspace = activeWorkspace else { return }
        for node in workspace.allTerminals {
            guard let sessionID = node.sessionID,
                  activity[sessionID] == nil,
                  let session = terminals.session(for: node.id), session.isRunning,
                  let message = AgentHooks.startupPrompt(onScreen: session.screenText)
            else { continue }
            var record = AgentActivity(sessionID: sessionID)
            record.state = .blocked
            record.message = message
            activity[sessionID] = record
            announce(record, node: node)
        }
    }

    private func terminalNode(forSession sessionID: String) -> TerminalNode? {
        guard let workspace = activeWorkspace else { return nil }
        return workspace.allTerminals.first { $0.sessionID == sessionID }
    }

    /// The orchestrator is hosted by the workspace node rather than having a
    /// card of its own, so a terminal does not always map to `.terminal`.
    func canvasID(for node: TerminalNode) -> NodeID {
        if let workspace = activeWorkspace, workspace.orchestrator?.id == node.id {
            return .workspace(workspace.id)
        }
        return .terminal(node.id)
    }

    /// Current state of one terminal. Terminals with no agent in them — and
    /// agents that have exited — report nothing.
    func activity(for node: TerminalNode) -> AgentActivity? {
        guard let sessionID = node.sessionID else { return nil }
        guard terminals.isRunning(node.id) else { return nil }
        return activity[sessionID]
    }

    func isUnread(_ id: UUID) -> Bool { unread.contains(id) }

    // MARK: - The hover guard
    //
    // The wheel pans the canvas, which is right almost everywhere — but it also
    // means a terminal can never be scrolled back through. Resting the pointer
    // on one hands it the wheel until the pointer leaves.

    func hoverTerminal(_ id: UUID?) {
        guard hoveredTerminal != id else { return }
        hoveredTerminal = id
        armTask?.cancel()
        armedTerminal = nil
        guard let id else { return }
        armTask = Task { [weak self] in
            try? await Task.sleep(for: MeshvyStore.armDelay)
            guard !Task.isCancelled else { return }
            guard let self, self.hoveredTerminal == id else { return }
            self.armedTerminal = id
        }
    }

    /// Agents stopped on something only you can answer.
    var agentsNeedingYou: [TerminalNode] {
        (activeWorkspace?.allTerminals ?? []).filter { activity(for: $0)?.state == .blocked }
    }

    /// Jumps to the next agent waiting on you, cycling through them if there
    /// are several. The one shortcut worth having on a busy board.
    func revealNextNeedingYou() {
        let ids = agentsNeedingYou.map { canvasID(for: $0) }
        guard !ids.isEmpty else {
            show(.init(kind: .info, title: "No agent is waiting on you", detail: nil))
            return
        }
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { ids.index(after: $0) % ids.count } ?? 0
        reveal(ids[next])
    }

    private func markRead(_ id: NodeID?) {
        let terminalID: UUID?
        switch id {
        case .terminal(let value): terminalID = value
        case .workspace: terminalID = activeWorkspace?.orchestrator?.id
        default: terminalID = nil
        }
        guard let terminalID, unread.remove(terminalID) != nil else { return }
        notifier.badge(agentsNeedingYou.count)
    }

    /// One agent typing into another's terminal.
    private func handleSend(_ request: AgentBridge.Request) {
        guard let target = request.to, let message = request.message,
              let workspace = activeWorkspace else { return }
        let node = workspace.terminals.first { $0.bridgeID == target }
            ?? (workspace.orchestrator?.bridgeID == target ? workspace.orchestrator : nil)
        guard let node, let session = terminals.session(for: node.id) else { return }
        session.send(message + "\r")
    }

    /// Starts Claude Code on the workspace node itself. Its working directory
    /// is the workspace root, so every repository is a subdirectory it can see.
    func startOrchestrator() {
        guard var workspace = activeWorkspace else { return }
        if let existing = workspace.orchestrator, terminals.isRunning(existing.id) {
            reveal(.workspace(workspace.id))
            return
        }
        guard FileManager.default.fileExists(atPath: workspace.root) else {
            show(.init(kind: .failure, title: "Workspace folder is missing", detail: workspace.root))
            return
        }

        let sessionID = UUID().uuidString.lowercased()
        let name = AgentCommand.derivedName(role: .orchestrator, context: workspace.name)
        var node = TerminalNode(
            role: .orchestrator,
            title: name,
            cwd: workspace.root,
            sessionID: sessionID
        )
        node.size = CGSize(width: workspace.boardWidth, height: workspace.boardHeight)
        node.permissionMode = permissionMode

        AgentBridge.install(for: workspace)
        let options = AgentCommand.Options(
            model: models.selectedModelID,
            permissionMode: permissionMode,
            settingsPath: AgentHooks.settingsPath(for: workspace)
        )
        terminals.start(
            node: node,
            command: AgentCommand.orchestrator(
                workspace: workspace, sessionID: sessionID, name: name, options: options
            ),
            // Puts `meshvy` on the orchestrator's PATH so it can delegate.
            environment: ["PATH": AgentBridge.binDirectory(for: workspace) + ":" + currentPath()]
        )
        workspace.orchestrator = node
        update(workspace)
        startBridge(for: workspace)
        selection = .workspace(workspace.id)
        refreshSubAgents()
    }

    func stopOrchestrator() {
        guard var workspace = activeWorkspace, let node = workspace.orchestrator else { return }
        terminals.discard(node.id)
        unread.remove(node.id)
        if let sessionID = node.sessionID { activity[sessionID] = nil }
        workspace.orchestrator = nil
        subAgents = []
        update(workspace)
        notifier.badge(agentsNeedingYou.count)
    }

    var isOrchestratorRunning: Bool {
        guard let node = activeWorkspace?.orchestrator else { return false }
        return terminals.isRunning(node.id)
    }

    /// Opens a terminal for one repository, or a plain shell.
    private func currentPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    @discardableResult
    func openTerminal(
        role: TerminalNode.Role,
        repoID: String? = nil,
        openingTask: String? = nil,
        bridgeID: String? = nil
    ) -> TerminalNode? {
        guard var workspace = activeWorkspace else { return nil }
        guard role != .orchestrator else { startOrchestrator(); return workspace.orchestrator }

        let repo = repoID.flatMap { id in workspace.repos.first { $0.id == id } }
        let cwd = repo?.worktreePath ?? workspace.root
        guard FileManager.default.fileExists(atPath: cwd) else {
            show(.init(kind: .failure, title: "That folder does not exist yet", detail: cwd))
            return nil
        }

        let sessionID = role == .shell ? nil : UUID().uuidString.lowercased()
        let name = AgentCommand.derivedName(role: role, context: repo?.name ?? workspace.name)
        var node = TerminalNode(
            role: role,
            title: openingTask.map { String($0.prefix(48)) }
                ?? (role == .shell ? (repo?.name ?? workspace.name) : name),
            cwd: cwd,
            repoID: repo?.id,
            sessionID: sessionID
        )
        node.size = CGSize(width: 580, height: 340)
        node.bridgeID = bridgeID
        node.openingTask = openingTask
        node.permissionMode = permissionMode

        let command: [String]
        if role == .shell {
            command = []
        } else {
            guard let repo else { return nil }
            command = AgentCommand.repoAgent(
                workspace: workspace, repo: repo, sessionID: sessionID!, name: name,
                task: openingTask,
                options: AgentCommand.Options(
                    model: models.selectedModelID,
                    permissionMode: permissionMode,
                    settingsPath: AgentHooks.settingsPath(for: workspace)
                )
            )
        }

        terminals.start(node: node, command: command)
        workspace.terminals.append(node)
        update(workspace)
        selection = .terminal(node.id)
        reveal(.terminal(node.id))
        return node
    }

    // MARK: - Sub-agents

    /// Re-reads the orchestrator's transcript for Agent-tool dispatches. Cheap
    /// enough to run on every transcript write while it is working.
    private func refreshSubAgents() {
        guard let sessionID = activeWorkspace?.orchestrator?.sessionID,
              let url = transcriptURL(for: sessionID) else {
            if !subAgents.isEmpty { subAgents = []; rebuild() }
            return
        }
        let tracker = subAgentTracker
        Task.detached(priority: .utility) {
            let found = tracker.subAgents(inTranscriptAt: url)
            await MainActor.run { [weak self] in
                guard let self, self.subAgents != found else { return }
                self.subAgents = found
                self.rebuild()
            }
        }
    }

    /// Transcripts are named after the session id, so a filename match finds it
    /// without having to re-derive the project folder encoding.
    private func transcriptURL(for sessionID: String) -> URL? {
        indexer.transcriptFiles().first { $0.deletingPathExtension().lastPathComponent == sessionID }
    }

    func closeTerminal(_ id: UUID) {
        terminals.discard(id)
        unread.remove(id)
        guard var workspace = activeWorkspace else { return }
        if let sessionID = workspace.terminals.first(where: { $0.id == id })?.sessionID {
            activity[sessionID] = nil
        }
        workspace.terminals.removeAll { $0.id == id }
        update(workspace)
        if selection == .terminal(id) { selection = nil }
        notifier.badge(agentsNeedingYou.count)
    }

    func restartTerminal(_ id: UUID) {
        guard let workspace = activeWorkspace else { return }
        if workspace.orchestrator?.id == id {
            stopOrchestrator()
            startOrchestrator()
            return
        }
        guard let node = workspace.terminals.first(where: { $0.id == id }) else { return }
        closeTerminal(id)
        openTerminal(role: node.role, repoID: node.repoID)
    }

    /// Persists a terminal's placement after a drag or resize.
    /// Resizes the workspace node itself.
    func resizeWorkspaceNode(to size: CGSize) {
        guard var workspace = activeWorkspace else { return }
        workspace.boardWidth = size.width
        workspace.boardHeight = size.height
        guard let position = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[position] = workspace
        if let node = graph.nodes.firstIndex(where: { $0.id == .workspace(workspace.id) }) {
            graph.nodes[node].size = size
            graph.nodes[node].kind = .workspace(workspace)
        }
    }

    func moveTerminal(_ id: UUID, to position: CGPoint, size: CGSize? = nil) {
        guard var workspace = activeWorkspace,
              let index = workspace.terminals.firstIndex(where: { $0.id == id }) else { return }
        workspace.terminals[index].position = position
        if let size { workspace.terminals[index].size = size }
        workspaces[workspaces.firstIndex { $0.id == workspace.id }!] = workspace
        if let node = graph.nodes.firstIndex(where: { $0.id == .terminal(id) }) {
            graph.nodes[node].position = position
            if let size { graph.nodes[node].size = size }
            graph.nodes[node].kind = .terminal(workspace.terminals[index])
        }
    }

    func commitTerminalMove() {
        persistWorkspaces()
        rebuild()
    }

    // MARK: - Indexing

    private func startIndexing(files: [URL], quiet: Bool = false) {
        isIndexing = true
        if !quiet { statusLine = "Indexing \(files.count) transcripts…" }
        let indexer = self.indexer

        Task.detached(priority: .userInitiated) {
            indexer.index(files: files) { batch in
                Task { @MainActor [weak self] in self?.merge(batch) }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isIndexing = false
                self.rebuild()
                self.fitIfNeeded()
                self.statusLine = self.summaryLine()
            }
        }
    }

    private func merge(_ batch: [SessionSummary]) {
        for summary in batch {
            if let position = sessionIndexByID[summary.id] {
                allSessions[position] = summary
            } else {
                allSessions.append(summary)
                sessionIndexByID[summary.id] = allSessions.count - 1
            }
        }
        guard !batch.isEmpty else { return }
        rebuild()
    }

    private func reindexChangedTranscripts() {
        guard hasWorkspace, !isIndexing else { return }
        startIndexing(files: indexer.transcriptFiles(), quiet: true)
    }

    func refreshAll() {
        guard hasWorkspace else { return }
        statusLine = "Refreshing…"
        refreshLive(rebuildGraph: false)
        startIndexing(files: indexer.transcriptFiles())
        refreshGitStatus()
    }

    // MARK: - Git

    func refreshGitStatus() {
        guard let workspace = activeWorkspace, !isLoadingGit else { return }
        isLoadingGit = true
        let paths = workspace.repos.map(\.worktreePath)

        Task.detached(priority: .utility) { [weak self] in
            await self?.readGitState(paths: paths)
        }
    }

    /// Reads dirty counts, divergence and tip commits per checkout, in bounded
    /// parallel waves so the board fills in as results land.
    private nonisolated func readGitState(paths: [String]) async {
        let git = GitService()
        let waveSize = 4
        var index = 0

        while index < paths.count {
            let wave = Array(paths[index..<min(index + waveSize, paths.count)])
            index += waveSize

            await withTaskGroup(of: (String, Worktree?, [FileChange]).self) { group in
                for path in wave {
                    group.addTask {
                        guard FileManager.default.fileExists(atPath: path) else { return (path, nil, []) }
                        let listed = git.listWorktrees(cwd: path)
                        let match = listed.first { $0.path == path }
                            ?? Worktree(
                                path: path, branch: nil, head: nil, isMain: false,
                                isDetached: false, isLocked: false, isPrunable: false
                            )
                        return (path, git.status(for: match), git.changes(at: path))
                    }
                }
                for await (path, worktree, fileChanges) in group {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let worktree { self.worktrees[path] = worktree }
                        self.changes[path] = fileChanges
                        self.rebuild()
                    }
                }
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.isLoadingGit = false
            self.fitIfNeeded()
            self.statusLine = self.summaryLine()
        }
    }

    // MARK: - Diffs

    /// Opens a file in the diff viewer. The diff is read on demand rather than
    /// with the status sweep — most files are never looked at.
    func openDiff(repoPath: String, change: FileChange) {
        openFile = (repoPath, change)
        openDiff = nil
        isLoadingDiff = true
        let git = self.git

        Task.detached(priority: .userInitiated) {
            let diff = git.diff(at: repoPath, file: change)
            await MainActor.run { [weak self] in
                guard let self, self.openFile?.change.path == change.path else { return }
                self.openDiff = diff
                self.isLoadingDiff = false
            }
        }
    }

    func closeDiff() {
        openFile = nil
        openDiff = nil
    }

    /// Changed files across every repository in the workspace.
    var workspaceChanges: [(repo: WorkspaceRepo, files: [FileChange])] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.repos.compactMap { repo in
            let files = changes[repo.worktreePath] ?? []
            return files.isEmpty ? nil : (repo, files)
        }
    }

    var totalChangedFiles: Int {
        workspaceChanges.reduce(0) { $0 + $1.files.count }
    }

    // MARK: - Live sessions

    func refreshLive(rebuildGraph: Bool = true) {
        let snapshot = liveMonitor.snapshot()
        var byID: [String: LiveSession] = [:]
        for session in snapshot {
            if let existing = byID[session.sessionId],
               (existing.updatedAt ?? .distantPast) > (session.updatedAt ?? .distantPast) { continue }
            byID[session.sessionId] = session
        }
        guard byID != live || !rebuildGraph else { return }
        live = byID
        if rebuildGraph { rebuild() }
    }

    // MARK: - Watching

    private func startWatching() {
        let home = NSHomeDirectory()
        watchers = [
            DirectoryWatcher(paths: [home + "/.claude/sessions"], debounce: 0.3) { [weak self] in
                Task { @MainActor in self?.refreshLive() }
            },
            DirectoryWatcher(paths: [home + "/.claude/projects"], debounce: 1.5) { [weak self] in
                Task { @MainActor in
                    self?.reindexChangedTranscripts()
                    // The orchestrator's dispatches land in the same transcript,
                    // so a write there may mean a new sub-agent.
                    self?.refreshSubAgents()
                }
            }
        ]
    }

    private func startTimers() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLive()
                // FSEvents is the fast path for hook payloads; this is the
                // backstop for the ones it coalesces away.
                self?.drainHooks()
            }
        }
        gitTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGitStatus() }
        }
    }

    // MARK: - Graph

    private func rebuild() {
        guard let workspace = activeWorkspace else {
            graph = CanvasGraph()
            return
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: allSessions.map { ($0.id, live[$0.id]?.status ?? .ended) }
        )
        graph = composer.compose(.init(
            workspace: workspace,
            worktrees: worktrees,
            sessions: allSessions,
            statuses: statuses,
            live: live,
            subAgents: subAgents,
            pinned: pinned,
            claimedSessions: terminals.claimedSessionIDs,
            showEnded: showEndedSessions,
            orchestratorRunning: isOrchestratorRunning
        ))
        recomputeMatches()
        if let selection, graph.node(selection) == nil { self.selection = nil }
    }

    private func recomputeMatches() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { matchingNodes = []; return }
        let terms = query.split(separator: " ").map(String.init)
        matchingNodes = Set(
            graph.nodes
                .filter { node in terms.allSatisfy { node.searchText.contains($0) } }
                .map { $0.id.storageKey }
        )
    }

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func matches(_ id: NodeID) -> Bool { matchingNodes.contains(id.storageKey) }

    private func summaryLine() -> String {
        guard let workspace = activeWorkspace else { return "No workspace — create one to get started" }
        let sessions = graph.nodes.filter { if case .session = $0.kind { return true } else { return false } }.count
        let running = workspace.allTerminals.filter { terminals.isRunning($0.id) }.count
        var parts = [
            "\(workspace.readyRepos.count) \(workspace.readyRepos.count == 1 ? "repo" : "repos") on \(workspace.branch)",
            "\(sessions) \(sessions == 1 ? "session" : "sessions")"
        ]
        if running > 0 { parts.append("\(running) \(running == 1 ? "terminal" : "terminals") running") }
        let working = workspace.allTerminals.filter { activity(for: $0)?.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        let blocked = agentsNeedingYou.count
        if blocked > 0 { parts.append("\(blocked) waiting on you") }
        return parts.joined(separator: "  ·  ")
    }

    func show(_ banner: Banner) {
        self.banner = banner
        let id = banner.id
        Task {
            try? await Task.sleep(for: .seconds(banner.kind == .failure ? 12 : 4))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    func dismissBanner() { banner = nil }

    // MARK: - Interaction

    func select(_ id: NodeID?) {
        selection = id
        markRead(id)
        guard case .session(let sessionID)? = id else { return }
        loadTranscript(sessionID)
    }

    func moveNode(_ id: NodeID, to position: CGPoint) {
        if case .terminal(let terminalID) = id {
            moveTerminal(terminalID, to: position)
            return
        }
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
        graph.nodes[index].isPinned = true
        pinned[id.storageKey] = position
    }

    func commitMove() { persistLayout(); persistWorkspaces() }

    func resetLayout() {
        pinned.removeAll()
        if var workspace = activeWorkspace {
            for index in workspace.terminals.indices { workspace.terminals[index].position = .zero }
            update(workspace)
        }
        rebuild()
        fit()
        persistLayout()
    }

    func persistLayout() {
        saved.pinned = pinned.mapValues { SavedLayout.Point(x: $0.x, y: $0.y) }
        saved.cameraX = viewport.center.x
        saved.cameraY = viewport.center.y
        saved.scale = viewport.scale
        saved.showEndedSessions = showEndedSessions
        saved.invertScroll = invertScroll
        saved.sidebarWidth = sidebarWidth
        saved.inspectorWidth = inspectorWidth
        saved.permissionMode = permissionMode.rawValue
        saved.notificationsEnabled = notifier.isEnabled
        layoutStore.save(saved)
    }

    // MARK: - Camera

    @discardableResult
    func fit() -> Bool {
        guard viewport.hasSize, let rect = graph.contentRect, !rect.isEmpty else { return false }
        viewport.fit(rect)
        persistLayout()
        return true
    }

    func fitIfNeeded() {
        guard !hasFitInitially else { return }
        if fit() { hasFitInitially = true }
    }

    func zoom(by factor: CGFloat) {
        viewport.zoom(to: viewport.scale * factor, anchor: viewport.screenCenter)
        persistLayout()
    }

    func zoomToActualSize() {
        viewport.zoom(to: 1, anchor: viewport.screenCenter)
        persistLayout()
    }

    func focusMatches() {
        let targets = isSearching ? graph.nodes.filter { matches($0.id) } : graph.nodes
        guard let rect = CGRect.bounding(targets.map(\.frame)) else { return }
        withAnimation(.easeOut(duration: 0.25)) { viewport.fit(rect, margin: 140) }
        persistLayout()
    }

    func reveal(_ id: NodeID) {
        guard let node = graph.node(id) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            viewport.scale = max(viewport.scale, 0.8)
            viewport.center = node.frame.center
        }
        selection = id
        markRead(id)
        if case .session(let sessionID) = id { loadTranscript(sessionID) }
    }

    // MARK: - Transcript

    private func loadTranscript(_ sessionID: String) {
        guard transcriptSessionID != sessionID else { return }
        guard let summary = allSessions.first(where: { $0.id == sessionID }) else { return }
        transcriptSessionID = sessionID
        transcript = nil
        isLoadingTranscript = true
        let loader = transcriptLoader

        Task.detached(priority: .userInitiated) {
            let loaded = loader.load(summary)
            await MainActor.run { [weak self] in
                guard let self, self.transcriptSessionID == sessionID else { return }
                self.transcript = loaded
                self.isLoadingTranscript = false
            }
        }
    }

    func reloadTranscript() {
        guard let id = transcriptSessionID else { return }
        transcriptSessionID = nil
        loadTranscript(id)
    }

    // MARK: - Shell-outs

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens the uninstaller in Terminal.
    ///
    /// Deliberately not run silently in-process: it hands git worktrees back to
    /// their repositories and can decline to remove checkouts holding unsaved
    /// work, and that conversation belongs in a terminal where it can be read
    /// and answered. The script ships inside the bundle.
    func runUninstaller() {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/uninstall.sh")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            show(.init(
                kind: .failure,
                title: "No uninstaller in this build",
                detail: "Run scripts/uninstall.sh from the repository instead."
            ))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", bundled.path]
        do {
            try process.run()
        } catch {
            show(.init(
                kind: .failure,
                title: "Could not open Terminal",
                detail: "Run this yourself:\n\(bundled.path)"
            ))
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealTranscriptFile(_ summary: SessionSummary) {
        NSWorkspace.shared.selectFile(
            summary.fileURL.path,
            inFileViewerRootedAtPath: summary.fileURL.deletingLastPathComponent().path
        )
    }
}
