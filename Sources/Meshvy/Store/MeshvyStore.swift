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

    /// Workspaces on the board and in the switcher.
    var liveWorkspaces: [Workspace] { workspaces.filter { !$0.isArchived } }
    /// Put away, newest first. Their worktrees are untouched on disk.
    var archivedWorkspaces: [Workspace] {
        workspaces.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

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
    /// Effort new agents start with. Unlike the permission mode this one *can*
    /// be retuned in a running session, with `/effort`.
    var agentEffort = AgentEffort.inherit { didSet { persistLayout() } }

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
    let browsers = BrowserRegistry()
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
    private var browserWatcher: DirectoryWatcher?
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
        // An archived workspace is not on the board, so it cannot be the one
        // open — including when the archive happened in an older version.
        if activeWorkspace?.isArchived ?? false { activeWorkspaceID = liveWorkspaces.first?.id }
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
        agentEffort = stored.effort.flatMap(AgentEffort.init(rawValue:)) ?? .inherit
        // Only once the user has actually chosen: nil doubles as "inherit the
        // CLI default", so an absent choice must not read as one.
        if stored.hasModelChoice == true { models.selectedModelID = stored.modelID }
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
        // Opening an archived workspace is how you un-archive it; there is no
        // sense in a board you can look at but which is still filed away.
        if workspaces.first(where: { $0.id == id })?.isArchived ?? false {
            unarchiveWorkspace(id)
            return
        }
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

    /// Puts a workspace away without touching a thing on disk.
    ///
    /// The destructive paths already exist — close, delete worktrees, delete and
    /// discard — and all three ask you to think. Most of the time what you want
    /// is neither: the branch is merged, you are done with it, and you would
    /// like it out of the switcher without being asked whether you are sure.
    /// That is this. Every worktree stays registered in its repository, and
    /// restoring is one click in the same menu.
    func archiveWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let name = workspaces[index].name
        // The processes do not belong to an archived board; the nodes do, and
        // they come back untouched when it is restored.
        for terminal in workspaces[index].allTerminals { terminals.discard(terminal.id) }
        for browser in workspaces[index].browsers { browsers.discard(browser.id) }
        workspaces[index].orchestrator = nil
        workspaces[index].terminals = []
        workspaces[index].archivedAt = Date()

        let wasOpen = activeWorkspaceID == id
        if wasOpen {
            activeWorkspaceID = liveWorkspaces.first?.id
            selection = nil
            transcript = nil
            transcriptSessionID = nil
            worktrees = [:]
            changes = [:]
            activity = [:]
            subAgents = []
            unread = []
            notifier.badge(0)
            hasFitInitially = false
        }
        persistWorkspaces()
        // Archiving a workspace you were not looking at should not cost you a
        // re-index of the one you were.
        if wasOpen {
            if hasWorkspace { loadActiveWorkspace() } else { graph = CanvasGraph() }
            statusLine = hasWorkspace ? summaryLine() : "No workspace — create one to get started"
        } else {
            rebuild()
        }
        show(.init(
            kind: .success,
            title: "Archived “\(name)”",
            detail: "The worktrees are untouched. Restore it from the workspace menu."
        ))
    }

    /// Brings one back and opens it.
    func unarchiveWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].archivedAt = nil
        let restored = workspaces[index].id
        persistWorkspaces()
        guard restored != activeWorkspaceID else { rebuild(); return }
        activeWorkspaceID = restored
        selection = nil
        hasFitInitially = false
        loadActiveWorkspace()
    }

    /// Forgets the workspace. `removeWorktrees` also tears the checkouts off disk.
    func deleteWorkspace(_ id: UUID, removeWorktrees: Bool, force: Bool) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        for terminal in workspace.allTerminals { terminals.discard(terminal.id) }
        for browser in workspace.browsers { browsers.discard(browser.id) }

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
            activeWorkspaceID = liveWorkspaces.first?.id
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
        BrowserBridge.install(for: workspace)
        BrowserBridge.sweepStaleResponses(for: workspace)
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
        // A tool call is a question an agent is sitting and waiting on, so this
        // one is as close to immediate as FSEvents will give.
        browserWatcher = DirectoryWatcher(
            paths: [BrowserBridge.requestsDirectory(for: workspace)],
            debounce: 0.05
        ) { [weak self] in
            Task { @MainActor in self?.drainBrowserBridge() }
        }
        drainBridge()
        drainBrowserBridge()
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
    // means a terminal can never be scrolled back through, and a page can never
    // be scrolled down. Resting the pointer on one hands it the wheel until the
    // pointer leaves. Terminals and browsers share this, since node ids are
    // unique across both.

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
        node.model = models.selectedModelID
        node.effort = agentEffort

        AgentBridge.install(for: workspace)
        BrowserBridge.install(for: workspace)
        let options = agentOptions(for: workspace)
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

    /// What every session Meshvy starts is launched with. One place, so the
    /// orchestrator and the agents it spawns can never drift apart.
    private func agentOptions(for workspace: Workspace) -> AgentCommand.Options {
        AgentCommand.Options(
            model: models.selectedModelID,
            permissionMode: permissionMode,
            effort: agentEffort,
            settingsPath: AgentHooks.settingsPath(for: workspace),
            mcpConfigPath: BrowserBridge.configPath(for: workspace)
        )
    }

    // MARK: - Retuning a session
    //
    // All three settings are chosen per board and remembered for the next
    // agent. Two of them can also be changed inside a session that is already
    // running, because the CLI has a command for them; the permission mode
    // cannot, so that one says so rather than pretending.

    /// Model for the next agent, and for this one if it is still running.
    func selectModel(_ id: String?, applyingTo node: TerminalNode? = nil) {
        models.selectedModelID = id
        persistLayout()
        guard let node else { return }
        guard let id else {
            show(.init(
                kind: .info,
                title: "New agents will use the CLI's own model",
                detail: "A running session keeps the model it started with."
            ))
            return
        }
        // Recorded on the node only if the session took it, so a card never
        // claims a model its agent is not on.
        if send("/model \(id)", to: node, saying: "switch to \(models.displayName(for: id))") {
            updateTerminal(node.id) { $0.model = id }
        }
    }

    /// Effort for the next agent, and for this one if it is still running.
    func selectEffort(_ effort: AgentEffort, applyingTo node: TerminalNode? = nil) {
        agentEffort = effort
        guard let node else { return }
        guard let level = effort.flag else {
            show(.init(
                kind: .info,
                title: "New agents will use the CLI's own effort level",
                detail: "A running session keeps the level it started with."
            ))
            return
        }
        if send("/effort \(level)", to: node, saying: "think with \(effort.label.lowercased()) effort") {
            updateTerminal(node.id) { $0.effort = effort }
        }
    }

    /// Permission mode for the next agent. A running session's mode is not
    /// something the CLI exposes, so this says how to change it instead of
    /// quietly doing nothing.
    func selectPermissionMode(_ mode: PermissionMode, notifyingAbout node: TerminalNode? = nil) {
        permissionMode = mode
        guard let node, terminals.isRunning(node.id) else { return }
        show(.init(
            kind: .info,
            title: "New agents will start in “\(mode.label)”",
            detail: "⇧⇥ cycles the mode inside \(node.title), or restart it to launch in this one."
        ))
    }

    /// Types a slash command into a running session, the way you would yourself.
    ///
    /// Returns false when there was no session to type into. An agent that is
    /// mid-turn still takes it — Claude Code queues what you type and runs it
    /// when the turn ends — but that is worth saying rather than leaving you to
    /// wonder why nothing changed.
    @discardableResult
    private func send(_ command: String, to node: TerminalNode, saying what: String) -> Bool {
        guard let session = terminals.session(for: node.id), session.isRunning else { return false }
        session.send(command + "\r")
        let isBusy = activity(for: node)?.state == .working
        show(.init(
            kind: .info,
            title: "Asked \(node.title) to \(what)",
            detail: isBusy ? "It is mid-turn, so this runs when the turn ends." : nil
        ))
        return true
    }

    /// Edits one terminal in place, wherever it lives on the workspace.
    private func updateTerminal(_ id: UUID, _ edit: (inout TerminalNode) -> Void) {
        guard var workspace = activeWorkspace else { return }
        if var node = workspace.orchestrator, node.id == id {
            edit(&node)
            workspace.orchestrator = node
        } else if let index = workspace.terminals.firstIndex(where: { $0.id == id }) {
            edit(&workspace.terminals[index])
        } else {
            return
        }
        update(workspace)
    }

    private func currentPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Opens a terminal for one repository, or a plain shell.
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
        node.model = models.selectedModelID
        node.effort = agentEffort

        let command: [String]
        if role == .shell {
            command = []
        } else {
            guard let repo else { return nil }
            command = AgentCommand.repoAgent(
                workspace: workspace, repo: repo, sessionID: sessionID!, name: name,
                task: openingTask,
                options: agentOptions(for: workspace)
            )
        }

        terminals.start(node: node, command: command)
        workspace.terminals.append(node)
        update(workspace)
        selection = .terminal(node.id)
        reveal(.terminal(node.id))
        return node
    }

    // MARK: - Browsers
    //
    // A workspace is repositories plus agents, but what the agents are building
    // is a running application — and until there was a browser on the board, the
    // only way to look at one was to leave Meshvy. A browser node is a real page
    // on the canvas: the person watches it, and the agent drives it through the
    // `browser_*` tools. See `BrowserBridge`.

    /// Puts a browser on the board. Reuses one already pointed at the same host
    /// and port rather than stacking a second node on top of it.
    @discardableResult
    func openBrowser(
        url: String = "",
        title: String? = nil,
        repoID: String? = nil,
        bridgeID: String? = nil,
        reveal shouldReveal: Bool = true
    ) -> BrowserNode? {
        guard var workspace = activeWorkspace else { return nil }

        // Empty is the menu item: a blank node whose address bar is the prompt.
        // Every agent-driven path arrives here with a URL.
        var target = ""
        var origin: String?
        if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = BrowserNode.normalize(url) else {
                show(.init(kind: .failure, title: "That is not a URL Meshvy can open", detail: url))
                return nil
            }
            target = normalized
            origin = URLComponents(string: normalized).flatMap { components -> String? in
                guard let host = components.host else { return nil }
                return host + (components.port.map { ":\($0)" } ?? "")
            }
        }
        if let origin, let existing = workspace.browsers.first(where: { $0.origin == origin }) {
            navigateBrowser(existing.id, to: target)
            if shouldReveal { reveal(.browser(existing.id)) }
            return activeWorkspace?.browsers.first { $0.id == existing.id }
        }

        var node = BrowserNode(
            title: title ?? (origin ?? "Browser"),
            url: target,
            repoID: repoID,
            bridgeID: bridgeID,
            hasFixedTitle: title != nil
        )
        node.size = CGSize(width: 880, height: 600)
        browsers.start(node: node)
        bindBrowser(node.id)
        workspace.browsers.append(node)
        update(workspace)
        if shouldReveal {
            selection = .browser(node.id)
            reveal(.browser(node.id))
        }
        return node
    }

    /// Mounts the engine for a node restored from a saved board, so an agent can
    /// address it before anyone has looked at it.
    func ensureBrowserRunning(_ id: UUID) -> BrowserSession? {
        guard let node = activeWorkspace?.browsers.first(where: { $0.id == id }) else { return nil }
        let session = browsers.session(for: id) ?? browsers.start(node: node)
        bindBrowser(id)
        return session
    }

    /// Writes the page's own URL and title back onto the node, so the board
    /// reopens where it was left and the header says what the page says.
    private func bindBrowser(_ id: UUID) {
        guard let session = browsers.session(for: id), session.onPageChange == nil else { return }
        session.onPageChange = { [weak self] url, pageTitle in
            guard let self, var workspace = self.activeWorkspace,
                  let index = workspace.browsers.firstIndex(where: { $0.id == id }) else { return }
            let node = workspace.browsers[index]
            guard node.url != url || node.pageTitle != pageTitle else { return }
            workspace.browsers[index].url = url
            workspace.browsers[index].pageTitle = pageTitle
            if !node.hasFixedTitle, let pageTitle, !pageTitle.isEmpty {
                workspace.browsers[index].title = pageTitle
            }
            self.update(workspace)
        }
    }

    func navigateBrowser(_ id: UUID, to url: String) {
        guard var workspace = activeWorkspace,
              let index = workspace.browsers.firstIndex(where: { $0.id == id }),
              let target = BrowserNode.normalize(url) else { return }
        workspace.browsers[index].url = target
        update(workspace)
        _ = ensureBrowserRunning(id)?.load(target)
    }

    func reloadBrowser(_ id: UUID) { ensureBrowserRunning(id)?.reload() }

    func closeBrowser(_ id: UUID) {
        browsers.discard(id)
        guard var workspace = activeWorkspace else { return }
        workspace.browsers.removeAll { $0.id == id }
        update(workspace)
        if selection == .browser(id) { selection = nil }
    }

    func moveBrowser(_ id: UUID, to position: CGPoint, size: CGSize? = nil) {
        guard var workspace = activeWorkspace,
              let index = workspace.browsers.firstIndex(where: { $0.id == id }) else { return }
        workspace.browsers[index].position = position
        if let size { workspace.browsers[index].size = size }
        workspaces[workspaces.firstIndex { $0.id == workspace.id }!] = workspace
        if let node = graph.nodes.firstIndex(where: { $0.id == .browser(id) }) {
            graph.nodes[node].position = position
            if let size { graph.nodes[node].size = size }
            graph.nodes[node].kind = .browser(workspace.browsers[index])
        }
    }

    // MARK: - Browser tools
    //
    // Everything below answers a `browser_*` tool call. Each one is a file the
    // MCP server dropped and is blocking on, so every path must write exactly
    // one answer back — including the failures.

    private func drainBrowserBridge() {
        guard let workspace = activeWorkspace else { return }
        for (url, request) in BrowserBridge.pendingRequests(for: workspace) {
            // Removed first: a request that throws must not be retried forever.
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor [weak self] in await self?.serve(request, in: workspace) }
        }
    }

    private func serve(_ request: BrowserBridge.Request, in workspace: Workspace) async {
        do {
            let result = try await perform(request)
            BrowserBridge.answer(
                .init(id: request.id, ok: true, result: result, error: nil), in: workspace
            )
        } catch {
            BrowserBridge.answer(
                .init(id: request.id, ok: false, result: nil, error: error.localizedDescription),
                in: workspace
            )
        }
    }

    private func perform(_ request: BrowserBridge.Request) async throws -> String {
        guard let workspace = activeWorkspace else {
            throw BrowserSession.BrowserError.message("no workspace is open in Meshvy")
        }

        switch request.op {
        case "open":
            guard let url = request.url else {
                throw BrowserSession.BrowserError.message("browser_open needs a url")
            }
            guard let node = openBrowser(url: url, title: request.title, bridgeID: request.node) else {
                throw BrowserSession.BrowserError.message("could not open \(url)")
            }
            return "Opened browser \(node.shortID) at \(node.url). "
                + "Pass node: \"\(node.shortID)\" to the other browser tools, or omit it while this is the only one."

        case "list":
            guard !workspace.browsers.isEmpty else { return "No browser nodes on the board yet." }
            return workspace.browsers.map { node in
                let session = browsers.session(for: node.id)
                let state = session?.isLoading == true ? "loading" : (session == nil ? "idle" : "loaded")
                let problems = session?.console.filter { $0.level == .error }.count ?? 0
                return "\(node.shortID)  \(state)  \(node.url)"
                    + (node.pageTitle.map { "  — \($0)" } ?? "")
                    + (problems > 0 ? "  [\(problems) console errors]" : "")
            }.joined(separator: "\n")

        case "close":
            let node = try resolve(request.node, in: workspace)
            closeBrowser(node.id)
            return "Closed browser \(node.shortID)."

        default:
            break
        }

        let node = try resolve(request.node, in: workspace)
        guard let session = ensureBrowserRunning(node.id) else {
            throw BrowserSession.BrowserError.message("browser \(node.shortID) is not running")
        }

        // What the page logs from here on is this action's doing, and is worth
        // handing back with the result rather than waiting to be asked.
        let mark = session.console.count

        switch request.op {
        case "navigate":
            guard let url = request.url else {
                throw BrowserSession.BrowserError.message("browser_navigate needs a url")
            }
            navigateBrowser(node.id, to: url)
            try await settle(session)
            return "Loaded \(session.url)." + consoleTail(session, since: 0)

        case "snapshot":
            try await settle(session)
            return try await session.snapshot().transcript

        case "click":
            guard let selector = request.selector else {
                throw BrowserSession.BrowserError.message("browser_click needs a selector")
            }
            let outcome = try await session.click(selector: selector)
            try await settle(session)
            return outcome + consoleTail(session, since: mark)

        case "type":
            guard let selector = request.selector, let text = request.text else {
                throw BrowserSession.BrowserError.message("browser_type needs a selector and text")
            }
            let outcome = try await session.type(
                selector: selector, text: text, submit: request.submit ?? false
            )
            try await settle(session)
            return outcome + consoleTail(session, since: mark)

        case "eval":
            guard let javaScript = request.js else {
                throw BrowserSession.BrowserError.message("browser_eval needs js")
            }
            return try await session.evaluate(javaScript)

        case "console":
            let limit = max(1, min(request.limit ?? 40, 200))
            let lines = session.console.suffix(limit)
            guard !lines.isEmpty else { return "The page has logged nothing." }
            return lines.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")

        case "screenshot":
            let data = try await session.screenshot()
            let directory = BrowserBridge.shotsDirectory(for: workspace)
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/\(node.shortID)-\(Int(Date().timeIntervalSince1970)).png"
            try data.write(to: URL(fileURLWithPath: path))
            return "Wrote \(path) — read it with the Read tool."

        case "wait":
            let timeout = Double(max(500, min(request.timeoutMs ?? 10_000, 120_000))) / 1000
            return try await session.waitFor(
                text: request.text, selector: request.selector, timeout: timeout
            )

        case "reload":
            session.reload()
            try await settle(session)
            return "Reloaded \(session.url)." + consoleTail(session, since: 0)

        case "back":
            guard session.canGoBack else {
                throw BrowserSession.BrowserError.message("nothing to go back to")
            }
            session.goBack()
            try await settle(session)
            return "Back at \(session.url)."

        default:
            throw BrowserSession.BrowserError.message("unknown browser op “\(request.op)”")
        }
    }

    /// Which browser a tool call means. One on the board needs no saying; more
    /// than one and the answer lists them rather than guessing.
    private func resolve(_ hint: String?, in workspace: Workspace) throws -> BrowserNode {
        if let hint, !hint.isEmpty {
            let needle = hint.lowercased()
            if let match = workspace.browsers.first(where: {
                $0.shortID == needle || $0.id.uuidString.lowercased() == needle
                    || $0.bridgeID?.lowercased() == needle
                    || $0.title.lowercased() == needle
            }) { return match }
            throw BrowserSession.BrowserError.message(
                "no browser “\(hint)” on the board. Open one with browser_open, "
                    + "or call browser_list to see them."
            )
        }
        switch workspace.browsers.count {
        case 0:
            throw BrowserSession.BrowserError.message(
                "there is no browser on the board — call browser_open with a url first"
            )
        case 1:
            return workspace.browsers[0]
        default:
            let ids = workspace.browsers.map { "\($0.shortID) (\($0.url))" }.joined(separator: ", ")
            throw BrowserSession.BrowserError.message(
                "there are \(workspace.browsers.count) browsers on the board — pass node: one of \(ids)"
            )
        }
    }

    /// Gives a navigation a moment to land, so a snapshot taken straight after a
    /// click reads the page that click produced rather than the one before it.
    private func settle(_ session: BrowserSession, within seconds: Double = 8) async throws {
        try? await Task.sleep(for: .milliseconds(120))
        let deadline = Date().addingTimeInterval(seconds)
        while session.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Errors the page threw while we were acting on it, counted from `since`
    /// so a click is not blamed for what the page logged on load. Attached to
    /// the result because that is the moment they matter, and an agent that has
    /// to ask twice usually does not ask at all. A navigation passes 0: it
    /// cleared the console's relevance anyway.
    private func consoleTail(_ session: BrowserSession, since mark: Int, limit: Int = 10) -> String {
        let problems = session.console.dropFirst(mark).filter { $0.level.isProblem }.suffix(limit)
        guard !problems.isEmpty else { return "" }
        return "\n\nThe page logged:\n"
            + problems.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")
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
                self?.drainBrowserBridge()
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
        if case .browser(let browserID) = id {
            moveBrowser(browserID, to: position)
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
            for index in workspace.browsers.indices { workspace.browsers[index].position = .zero }
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
        saved.effort = agentEffort.rawValue
        saved.hasModelChoice = true
        saved.modelID = models.selectedModelID
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

    /// Hands a page to the user's real browser — for the moment a canvas node
    /// is not the right place to be, like signing in or opening devtools.
    func openInBrowser(_ url: String) {
        guard let normalized = BrowserNode.normalize(url), let target = URL(string: normalized) else { return }
        NSWorkspace.shared.open(target)
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
