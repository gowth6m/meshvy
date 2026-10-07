import AppKit
import Observation
import SwiftUI

/// Everything the board renders from, plus the refresh machinery.
///
/// The unit of work is a workspace: a set of repositories you treat as one
/// project. A fresh install has none, so the board starts empty and the user
/// picks what goes on it. Refresh runs on three paths at different costs — live
/// agent status is cheap and frequent, transcript indexing is incremental and
/// driven by filesystem events, and git status is the slowest so it runs on a
/// longer timer.
@MainActor
@Observable
final class ForgeStore {
    // MARK: Workspaces
    private(set) var workspaces: [Workspace] = []
    private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == activeWorkspaceID }
    }

    var hasWorkspace: Bool { activeWorkspace != nil }

    // MARK: Data
    /// Every transcript on disk, indexed once and reused across workspaces.
    private(set) var allSessions: [SessionSummary] = []
    /// Live git state for the active workspace, keyed by repo id.
    private(set) var worktreesByRepo: [String: [Worktree]] = [:]
    private(set) var live: [String: LiveSession] = [:]
    private(set) var sections: [BoardSection] = []
    private(set) var graph = CanvasGraph()

    // MARK: View state
    var viewport = Viewport()
    var selection: NodeID?
    var searchQuery = "" { didSet { recomputeMatches() } }
    private(set) var matchingNodes: Set<String> = []

    var grouping: BoardComposer.Grouping = .link { didSet { rebuild(); persistLayout() } }
    var showEndedSessions = true { didSet { rebuild(); persistLayout() } }
    var invertScroll = false { didSet { persistLayout() } }
    var inspectorVisible = true

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
    private let indexer = SessionIndexer()
    private let liveMonitor = LiveSessionMonitor()
    private let git = GitService()
    private let linkedWorktrees = WorktreeLinker()
    private let launcher = AgentLauncher()
    private let composer = BoardComposer()
    /// Models offered in the launch sheet; refreshes from the Models API when a
    /// key is configured.
    let models = ModelCatalog()
    private let workspaceStore = WorkspaceStore()
    private let layoutStore = FileStore<SavedLayout>(filename: "layout.json")
    private let transcriptLoader = TranscriptLoader()

    private var saved = SavedLayout()
    private var pinned: [String: CGPoint] = [:]
    private var watchers: [DirectoryWatcher] = []
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
        workspaces = document.workspaces
        activeWorkspaceID = document.activeWorkspaceID ?? document.workspaces.first?.id

        refreshLive(rebuildGraph: false)
        startWatching()
        startTimers()
        models.refresh()

        guard hasWorkspace else {
            statusLine = "No workspace — add one to get started"
            return
        }
        loadActiveWorkspace()
    }

    private func loadSavedLayout() {
        guard let stored = layoutStore.load() else { return }
        saved = stored
        pinned = stored.pinned.mapValues { CGPoint(x: $0.x, y: $0.y) }
        grouping = BoardComposer.Grouping(rawValue: stored.grouping) ?? .link
        showEndedSessions = stored.showEndedSessions
        invertScroll = stored.invertScroll
        viewport.center = CGPoint(x: stored.cameraX, y: stored.cameraY)
        viewport.scale = max(Viewport.minScale, min(Viewport.maxScale, stored.scale))
        hasFitInitially = stored.scale > 0
    }

    /// Indexes transcripts and reads git state for the active workspace.
    private func loadActiveWorkspace() {
        let files = indexer.transcriptFiles()
        allSessions = indexer.quickSummaries(files: files).sorted { $0.lastActivityAt > $1.lastActivityAt }
        reindexLookup()
        rebuild()
        startIndexing(files: files)
        refreshGitStatus()
    }

    // MARK: - Workspace management

    @discardableResult
    func createWorkspace(name: String, repos: [WorkspaceRepo]) -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Workspace" : trimmed
        let workspace = Workspace(
            name: resolved,
            repos: repos,
            worktreeRoot: Workspace.defaultWorktreeRoot(for: resolved)
        )
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id
        persistWorkspaces()
        hasFitInitially = false
        loadActiveWorkspace()
        return workspace
    }

    func activate(_ id: UUID) {
        guard id != activeWorkspaceID else { return }
        activeWorkspaceID = id
        selection = nil
        transcript = nil
        transcriptSessionID = nil
        worktreesByRepo = [:]
        hasFitInitially = false
        persistWorkspaces()
        loadActiveWorkspace()
    }

    func deleteWorkspace(_ id: UUID) {
        // Removes Forge's record only; checkouts on disk are left alone.
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id {
            activeWorkspaceID = workspaces.first?.id
            worktreesByRepo = [:]
            hasFitInitially = false
        }
        persistWorkspaces()
        if hasWorkspace { loadActiveWorkspace() } else { sections = []; graph = CanvasGraph() }
        statusLine = hasWorkspace ? summaryLine() : "No workspace — add one to get started"
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        guard let position = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[position].name = name
        persistWorkspaces()
        rebuild()
    }

    /// Resolves picked folders into repositories, skipping anything that is not
    /// a git checkout and anything already in the workspace.
    func inspectRepos(at paths: [String]) -> (repos: [WorkspaceRepo], rejected: [String]) {
        var repos: [WorkspaceRepo] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let repo = linkedWorktrees.inspectRepo(at: path) else {
                rejected.append(URL(fileURLWithPath: path).lastPathComponent)
                continue
            }
            guard seen.insert(repo.id).inserted else { continue }
            repos.append(repo)
        }
        return (repos, rejected)
    }

    func addRepos(_ repos: [WorkspaceRepo]) {
        guard var workspace = activeWorkspace else { return }
        let existing = Set(workspace.repos.map(\.id))
        let fresh = repos.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else {
            show(.init(kind: .info, title: "Already in this workspace", detail: nil))
            return
        }
        workspace.repos.append(contentsOf: fresh)
        update(workspace)
        show(.init(
            kind: .success,
            title: "Added \(fresh.count) \(fresh.count == 1 ? "repository" : "repositories")",
            detail: fresh.map(\.name).joined(separator: ", ")
        ))
        refreshGitStatus()
    }

    func removeRepo(_ repoID: String) {
        guard var workspace = activeWorkspace else { return }
        workspace.repos.removeAll { $0.id == repoID }
        for position in workspace.linkedWorktrees.indices {
            workspace.linkedWorktrees[position].checkouts.removeAll { $0.repoID == repoID }
        }
        worktreesByRepo[repoID] = nil
        update(workspace)
    }

    /// Clones remotes into the workspace's checkout root and adds them.
    func cloneRepos(_ references: [String]) {
        guard let workspace = activeWorkspace else { return }
        let directory = workspace.worktreeRoot + "/repos"
        let service = linkedWorktrees
        isWorking = true
        show(.init(kind: .info, title: "Cloning \(references.count)…", detail: nil))

        Task.detached(priority: .userInitiated) {
            let outcomes = references.map { ($0, service.clone($0, into: directory)) }
            let cloned: [WorkspaceRepo] = outcomes.compactMap {
                if case .cloned(let repo) = $0.1 { return repo } else { return nil }
            }
            let failures: [String] = outcomes.compactMap {
                if case .failed(let message) = $0.1 { return "\($0.0): \(message)" } else { return nil }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                if !cloned.isEmpty { self.addRepos(cloned) }
                if !failures.isEmpty {
                    self.show(.init(
                        kind: .failure,
                        title: "\(failures.count) clone\(failures.count == 1 ? "" : "s") failed",
                        detail: failures.joined(separator: "\n")
                    ))
                }
            }
        }
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

    // MARK: - Linked worktrees

    /// Creates the same branch as a worktree in every repo of the workspace.
    func createLink(name: String, branch: String, baseRef: String?, intent: String?) {
        guard let workspace = activeWorkspace else { return }
        let service = linkedWorktrees
        isWorking = true
        show(.init(kind: .info, title: "Creating worktrees in \(workspace.repos.count) repos…", detail: nil))

        Task.detached(priority: .userInitiated) {
            let outcome = service.createLink(
                name: name, branch: branch, baseRef: baseRef, intent: intent, in: workspace
            )
            await MainActor.run { [weak self] in
                guard let self, var current = self.activeWorkspace else { return }
                self.isWorking = false
                current.linkedWorktrees.append(outcome.link)
                self.update(current)

                let ready = outcome.link.checkouts.filter(\.isReady).count
                if outcome.succeeded {
                    self.show(.init(
                        kind: .success,
                        title: "LinkedWorktree “\(name)” ready in \(ready) \(ready == 1 ? "repo" : "repos")",
                        detail: outcome.link.checkouts.first?.path
                    ))
                } else {
                    self.show(.init(
                        kind: .failure,
                        title: "LinkedWorktree “\(name)” created in \(ready) of \(outcome.link.checkouts.count) repos",
                        detail: outcome.failures.joined(separator: "\n")
                    ))
                }
                self.refreshGitStatus()
                self.hasFitInitially = false
                self.fitIfNeeded()
            }
        }
    }

    func removeLink(_ linkID: UUID, force: Bool, deleteBranch: Bool) {
        guard let workspace = activeWorkspace,
              let link = workspace.linkedWorktrees.first(where: { $0.id == linkID }) else { return }
        let service = linkedWorktrees
        isWorking = true

        Task.detached(priority: .userInitiated) {
            let failures = service.removeLink(link, in: workspace, force: force, deleteBranch: deleteBranch)
            await MainActor.run { [weak self] in
                guard let self, var current = self.activeWorkspace else { return }
                self.isWorking = false
                if failures.isEmpty {
                    current.linkedWorktrees.removeAll { $0.id == linkID }
                    self.update(current)
                    self.show(.init(kind: .success, title: "Removed link “\(link.name)”", detail: nil))
                } else {
                    self.show(.init(
                        kind: .failure,
                        title: "Could not remove every worktree",
                        detail: failures.joined(separator: "\n") + "\n\nUse “force” to discard uncommitted work."
                    ))
                }
                self.refreshGitStatus()
            }
        }
    }

    func linkedWorktree(for id: UUID?) -> LinkedWorktree? {
        guard let id, let workspace = activeWorkspace else { return nil }
        return workspace.linkedWorktrees.first { $0.id == id }
    }

    // MARK: - Agents

    func launchAgent(_ request: AgentLaunch) {
        do {
            let launched = try launcher.launch(request)
            show(.init(
                kind: .success,
                title: "Launched \(launched.name)",
                detail: request.runsInBackground
                    ? "Running in the background — it will appear on the board in a moment."
                    : "Opened in Terminal."
            ))
            // The CLI registers itself within about half a second; poll briefly
            // so the card shows up without waiting for the next tick.
            Task {
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    refreshLive()
                    if live[launched.sessionID] != nil { break }
                }
            }
        } catch {
            show(.init(
                kind: .failure,
                title: "Could not launch the agent",
                detail: error.localizedDescription
            ))
        }
    }

    /// Prefilled launch request for a node. Scope follows what was clicked: a
    /// card inside a linked worktree targets that link, a lone checkout targets
    /// itself, and nothing selected targets the whole workspace.
    func launchTemplate(for node: NodeID?) -> AgentLaunch {
        if let node, let link = linkedWorktree(containing: node) {
            return template(scope: .link(link.id))
        }
        if let path = node?.worktreePath {
            return template(scope: .checkout(path))
        }
        return template(scope: .workspace)
    }

    /// An agent that owns every repository in the workspace and every linked
    /// worktree cut across them.
    func workspaceLaunchTemplate() -> AgentLaunch { template(scope: .workspace) }

    func template(scope: AgentScope) -> AgentLaunch {
        var request = AgentLaunch()
        request.scope = scope
        guard let workspace = activeWorkspace else { return request }

        switch scope {
        case .workspace:
            // Start in a checkout rather than a parent folder so the agent has a
            // real git context; everything else comes in through --add-dir.
            let linkPaths = workspace.linkedWorktrees
                .flatMap { $0.checkouts.filter(\.isReady).map(\.path) }
                .filter { FileManager.default.fileExists(atPath: $0) }
            let repoPaths = workspace.repos.map(\.path)
            request.cwd = linkPaths.first ?? repoPaths.first ?? ""
            request.additionalDirs = repoPaths + linkPaths
            request.brief = AgentLauncher.workspaceSummary(
                workspace: workspace,
                linkedWorktrees: workspace.linkedWorktrees
            )

        case .link(let id):
            guard let link = workspace.linkedWorktrees.first(where: { $0.id == id }) else { break }
            let ready = link.checkouts.filter(\.isReady)
            request.cwd = ready.first?.path ?? ""
            request.additionalDirs = ready.map(\.path)
            request.brief = AgentLauncher.linkSummary(link: link, workspace: workspace)

        case .checkout(let path):
            request.cwd = path
            request.additionalDirs = [path]
            if let link = workspace.linkedWorktrees.first(where: { $0.paths.contains(path) }) {
                request.brief = AgentLauncher.linkSummary(link: link, workspace: workspace)
            }
        }
        return request
    }

    /// The linked worktree a node belongs to.
    func linkedWorktree(containing node: NodeID) -> LinkedWorktree? {
        linkedWorktree(for: graph.node(node)?.linkID)
    }

    // MARK: - Indexing

    /// `quiet` suppresses the progress text. Live sessions append constantly, so
    /// follow-up passes must not strobe the status line.
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

    private func reindexLookup() {
        sessionIndexByID = Dictionary(
            allSessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
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
        let repos = workspace.repos

        Task.detached(priority: .utility) { [weak self] in
            await self?.readGitState(for: repos)
        }
    }

    /// Lists each repo's worktrees, then fills in dirty counts, divergence and
    /// tip commits. This is by far the slowest refresh — several `git`
    /// invocations per worktree — so repos run in bounded parallel waves and the
    /// board updates as each one lands.
    private nonisolated func readGitState(for repos: [WorkspaceRepo]) async {
        let git = GitService()
        let waveSize = 4
        var index = 0

        while index < repos.count {
            let wave = Array(repos[index..<min(index + waveSize, repos.count)])
            index += waveSize

            await withTaskGroup(of: (String, [Worktree]).self) { group in
                for repo in wave {
                    group.addTask {
                        let listed = git.listWorktrees(cwd: repo.path)
                        return (repo.id, listed.map(git.status(for:)))
                    }
                }
                for await (repoID, worktrees) in group {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.worktreesByRepo[repoID] = worktrees
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

    // MARK: - Live sessions

    func refreshLive(rebuildGraph: Bool = true) {
        let snapshot = liveMonitor.snapshot()
        var byID: [String: LiveSession] = [:]
        for session in snapshot {
            // A session id can appear twice if a stale registry file lingers;
            // prefer the most recently updated entry.
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
                Task { @MainActor in self?.reindexChangedTranscripts() }
            }
        ]
    }

    private func startTimers() {
        liveTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
        gitTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshGitStatus() }
        }
    }

    // MARK: - Graph

    private func rebuild() {
        guard let workspace = activeWorkspace else {
            sections = []
            graph = CanvasGraph()
            return
        }

        let statuses = Dictionary(
            uniqueKeysWithValues: allSessions.map { ($0.id, live[$0.id]?.status ?? .ended) }
        )

        // Scope to this workspace: only sessions that ran somewhere under one of
        // its repositories, including worktrees that have since been removed.
        let scope = WorkspaceScope(workspace: workspace, worktreesByRepo: worktreesByRepo)
        var visible = allSessions.filter { scope.contains($0.resolvedPath) }
        if !showEndedSessions {
            visible = visible.filter { statuses[$0.id]?.isLive == true }
        }

        sections = composer.compose(.init(
            workspace: workspace,
            worktreesByRepo: worktreesByRepo,
            sessions: visible,
            grouping: grouping
        ))

        graph = BoardLayout().build(.init(
            sections: sections,
            statuses: statuses,
            live: live,
            pinned: pinned
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
        guard let workspace = activeWorkspace else { return "No workspace — add one to get started" }
        let worktrees = worktreesByRepo.values.reduce(0) { $0 + $1.count }
        let sessionCount = sections.reduce(0) { $0 + $1.sessionCount }
        let busy = live.values.filter { $0.status == .busy }.count
        var parts = [
            "\(workspace.repos.count) \(workspace.repos.count == 1 ? "repo" : "repos")",
            "\(workspace.linkedWorktrees.count) \(workspace.linkedWorktrees.count == 1 ? "link" : "linkedWorktrees")",
            "\(worktrees) worktrees",
            "\(sessionCount) sessions"
        ]
        if busy > 0 { parts.append("\(busy) working") }
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
        guard case .session(let sessionID)? = id else { return }
        loadTranscript(sessionID)
    }

    func moveNode(_ id: NodeID, to position: CGPoint) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
        graph.nodes[index].isPinned = true
        pinned[id.storageKey] = position
    }

    func commitMove() { persistLayout() }

    func resetLayout() {
        pinned.removeAll()
        rebuild()
        fit()
        persistLayout()
    }

    func persistLayout() {
        saved.pinned = pinned.mapValues { SavedLayout.Point(x: $0.x, y: $0.y) }
        saved.cameraX = viewport.center.x
        saved.cameraY = viewport.center.y
        saved.scale = viewport.scale
        saved.grouping = grouping.rawValue
        saved.showEndedSessions = showEndedSessions
        saved.invertScroll = invertScroll
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

    /// Frames the board the first time it can be framed. Called both when data
    /// arrives and when the canvas reports its size, since either can be last.
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
            viewport.scale = max(viewport.scale, 0.85)
            viewport.center = node.frame.center
        }
        selection = id
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

    func openInTerminal(_ path: String) {
        runAppleScript("""
        tell application "Terminal"
            activate
            do script "cd \(AgentLauncher.appleScriptEscape(AgentLauncher.shellQuote(path)))"
        end tell
        """)
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

    func resumeSession(_ summary: SessionSummary) {
        let path = summary.resolvedPath
        guard FileManager.default.fileExists(atPath: path) else {
            show(.init(kind: .failure, title: "That folder no longer exists", detail: path))
            return
        }
        let command = "cd \(AgentLauncher.shellQuote(path)) && claude --resume \(summary.id)"
        runAppleScript("""
        tell application "Terminal"
            activate
            do script "\(AgentLauncher.appleScriptEscape(command))"
        end tell
        """)
    }

    private func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error, let message = error[NSAppleScript.errorMessage] as? String {
            show(.init(kind: .failure, title: "Terminal did not open", detail: message))
        }
    }
}

/// Tests whether a path belongs to a workspace.
///
/// Matches live worktrees first, then falls back to the repo and link paths on
/// record — so a session whose checkout has since been deleted still lands in
/// the workspace it was run from.
private struct WorkspaceScope {
    private let index: PathIndex

    init(workspace: Workspace, worktreesByRepo: [String: [Worktree]]) {
        var paths = worktreesByRepo.values.flatMap { $0.map(\.path) }
        paths.append(contentsOf: workspace.repos.map(\.path))
        paths.append(contentsOf: workspace.linkedWorktrees.flatMap(\.paths))
        paths.append(workspace.worktreeRoot)
        index = PathIndex(paths: paths)
    }

    func contains(_ path: String) -> Bool { index.owner(of: path) != nil }
}

extension NodeID {
    var worktreePath: String? {
        if case .worktree(let path) = self { return path }
        return nil
    }
}
