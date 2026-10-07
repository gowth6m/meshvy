import AppKit
import Observation
import SwiftUI

/// Everything the board renders from, plus the refresh machinery.
///
/// Three refresh paths run at different costs: live status is cheap and frequent,
/// transcript indexing is incremental and triggered by filesystem events, and git
/// status is the slowest so it runs on a longer timer.
@MainActor
@Observable
final class ForgeStore {
    // MARK: Data
    private(set) var sessions: [SessionSummary] = []
    /// Real git state, as reported by `git worktree list`.
    private(set) var repos: [Repo] = []
    /// What the board shows: `repos` plus archived lanes reconstructed from
    /// session history. Derived on every rebuild; never written to git.
    private(set) var boardRepos: [Repo] = []
    private(set) var live: [String: LiveSession] = [:]
    private(set) var graph = CanvasGraph()

    // MARK: View state
    var viewport = Viewport()
    var selection: NodeID?
    var searchQuery = "" { didSet { recomputeMatches() } }
    private(set) var matchingNodes: Set<String> = []

    var groupByRepo = true { didSet { rebuild(); persistLayout() } }
    var showEndedSessions = true { didSet { rebuild(); persistLayout() } }

    var inspectorVisible = true
    private(set) var isIndexing = false
    private(set) var isLoadingGit = false
    private(set) var statusLine = "Starting up"

    // MARK: Transcript reader
    private(set) var transcript: Transcript?
    private(set) var transcriptSessionID: String?
    private(set) var isLoadingTranscript = false

    // MARK: Collaborators
    private let indexer = SessionIndexer()
    private let assembler = RepoAssembler()
    private let scanner = WorkspaceScanner()
    private let liveMonitor = LiveSessionMonitor()
    private let git = GitService()
    private let layoutStore = FileStore<SavedLayout>(filename: "layout.json")
    private let transcriptLoader = TranscriptLoader()

    private var saved = SavedLayout()
    private var pinned: [String: CGPoint] = [:]
    private var watchers: [DirectoryWatcher] = []
    private var liveTimer: Timer?
    private var gitTimer: Timer?
    private var hasFitInitially = false
    private var sessionIndexByID: [String: Int] = [:]

    // MARK: - Lifecycle

    private var hasBootstrapped = false

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        loadSavedLayout()

        // First frame: filesystem metadata only, so the board is never empty.
        let files = indexer.transcriptFiles()
        sessions = indexer.quickSummaries(files: files).sorted { $0.lastActivityAt > $1.lastActivityAt }
        reindexLookup()
        refreshLive(rebuildGraph: false)
        rebuild()
        statusLine = "\(sessions.count) sessions"

        startIndexing(files: files)
        startGitDiscovery()
        startWatching()
        startTimers()
    }

    private func loadSavedLayout() {
        guard let stored = layoutStore.load() else { return }
        saved = stored
        pinned = stored.pinned.mapValues { CGPoint(x: $0.x, y: $0.y) }
        groupByRepo = stored.groupByRepo
        showEndedSessions = stored.showEndedSessions
        viewport.center = CGPoint(x: stored.cameraX, y: stored.cameraY)
        viewport.scale = max(Viewport.minScale, min(Viewport.maxScale, stored.scale))
        hasFitInitially = stored.scale > 0
    }

    // MARK: - Indexing

    /// `quiet` suppresses the progress text. Live sessions append constantly, so
    /// the follow-up passes must not strobe the status line.
    private func startIndexing(files: [URL], quiet: Bool = false) {
        isIndexing = true
        if !quiet { statusLine = "Indexing \(files.count) transcripts…" }
        let indexer = self.indexer

        Task.detached(priority: .userInitiated) {
            indexer.index(files: files) { batch in
                Task { @MainActor [weak self] in
                    self?.merge(batch)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isIndexing = false
                self.rebuild()
                self.statusLine = self.summaryLine()
            }
        }
    }

    private func merge(_ batch: [SessionSummary]) {
        var touched = false
        for summary in batch {
            if let position = sessionIndexByID[summary.id] {
                sessions[position] = summary
            } else {
                sessions.append(summary)
                sessionIndexByID[summary.id] = sessions.count - 1
            }
            touched = true
        }
        guard touched else { return }
        // Cheap in-place refresh of node payloads; full relayout waits for the
        // end of the pass so cards do not jump around while indexing.
        rebuild()
    }

    private func reindexLookup() {
        sessionIndexByID = Dictionary(
            sessions.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
    }

    // MARK: - Git

    private func startGitDiscovery() {
        isLoadingGit = true
        let candidates = gitCandidatePaths()
        let git = self.git

        Task.detached(priority: .utility) {
            let discovered = git.discoverRepos(candidates: candidates)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.repos = discovered
                self.rebuild()
                self.fitIfNeeded()
                self.statusLine = self.summaryLine()
            }
            await self.enrich(repos: discovered, relist: false)
        }
    }

    func refreshGitStatus() {
        guard !isLoadingGit else { return }
        isLoadingGit = true
        let snapshot = repos
        Task.detached(priority: .utility) { [weak self] in
            await self?.enrich(repos: snapshot, relist: true)
        }
    }

    /// Fills in dirty counts, divergence and tip commits.
    ///
    /// This is by far the slowest refresh — several `git` invocations per
    /// worktree, and a busy machine can have fifty of them — so repos run in
    /// bounded parallel waves and the board updates as each one lands rather
    /// than waiting for the whole sweep.
    private nonisolated func enrich(repos snapshot: [Repo], relist: Bool) async {
        let git = GitService()
        let waveSize = 6
        var index = 0

        while index < snapshot.count {
            let wave = Array(snapshot[index..<min(index + waveSize, snapshot.count)])
            index += waveSize

            await withTaskGroup(of: Repo.self) { group in
                for repo in wave {
                    group.addTask {
                        var updated = repo
                        let worktrees = relist ? git.listWorktrees(cwd: repo.mainPath) : repo.worktrees
                        updated.worktrees = worktrees.map(git.status(for:))
                        return updated
                    }
                }
                for await updated in group {
                    await MainActor.run { [weak self] in self?.apply(updated) }
                }
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.isLoadingGit = false
            self.statusLine = self.summaryLine()
        }
    }

    /// Merges one repo's freshly read git state into the board.
    private func apply(_ repo: Repo) {
        guard !repo.worktrees.isEmpty,
              let position = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[position] = repo
        rebuild()
    }

    /// Any directory that might sit inside a repository. `git worktree list`
    /// expands one hit into every linked worktree, so this does not need to be
    /// exhaustive — just one path per repo.
    private func gitCandidatePaths() -> [String] {
        var candidates = Set<String>()
        for session in sessions {
            let path = session.resolvedPath
            if FileManager.default.fileExists(atPath: path) { candidates.insert(path) }
        }
        for session in live.values {
            if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) { candidates.insert(cwd) }
        }
        // Repos you have not opened with Claude yet still belong on the board.
        candidates.formUnion(scanner.candidateDirectories())
        return Array(candidates)
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
            DirectoryWatcher(
                paths: [home + "/.claude/sessions"],
                debounce: 0.3
            ) { [weak self] in
                Task { @MainActor in self?.refreshLive() }
            },
            DirectoryWatcher(
                paths: [home + "/.claude/projects"],
                debounce: 1.5
            ) { [weak self] in
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

    /// Re-runs the indexer. Unchanged files hit the cache and growing files only
    /// scan their appended bytes, so this stays cheap enough to run on every
    /// burst of transcript writes.
    private func reindexChangedTranscripts() {
        guard !isIndexing else { return }
        let files = indexer.transcriptFiles()
        let known = Set(sessions.map(\.id))
        let discovered = files.map { $0.deletingPathExtension().lastPathComponent }
        let hasNewSessions = !Set(discovered).subtracting(known).isEmpty
        startIndexing(files: files, quiet: true)
        if hasNewSessions { hasFitInitially = hasFitInitially && !pinned.isEmpty }
    }

    func refreshAll() {
        statusLine = "Refreshing…"
        refreshLive(rebuildGraph: false)
        startIndexing(files: indexer.transcriptFiles())
        refreshGitStatus()
    }

    // MARK: - Graph

    private func rebuild() {
        let statuses = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, live[$0.id]?.status ?? .ended) }
        )
        let visible = showEndedSessions
            ? sessions
            : sessions.filter { statuses[$0.id]?.isLive == true }

        let assembled = assembler.assemble(repos: repos, sessions: visible)
        boardRepos = assembled.repos

        graph = BoardLayout().build(.init(
            repos: assembled.repos,
            sessions: visible,
            attachment: assembled.attachment,
            unattached: assembled.unattached,
            statuses: statuses,
            live: live,
            pinned: pinned,
            groupByRepo: groupByRepo
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
        let liveCount = live.count
        let busy = live.values.filter { $0.status == .busy }.count
        let worktreeCount = repos.reduce(0) { $0 + $1.worktrees.count }
        var parts = ["\(sessions.count) sessions", "\(repos.count) repos", "\(worktreeCount) worktrees"]
        if liveCount > 0 { parts.append("\(liveCount) live" + (busy > 0 ? " · \(busy) working" : "")) }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Interaction

    func select(_ id: NodeID?) {
        selection = id
        guard case .session(let sessionID)? = id else { return }
        loadTranscript(sessionID)
    }

    func moveNode(_ id: NodeID, to position: CGPoint) {
        guard let position0 = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[position0].position = position
        graph.nodes[position0].isPinned = true
        pinned[id.storageKey] = position
    }

    func commitMove() {
        persistLayout()
    }

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
        saved.groupByRepo = groupByRepo
        saved.showEndedSessions = showEndedSessions
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

    /// Frames the current search hits, or everything when the query is empty.
    func focusMatches() {
        let targets = isSearching
            ? graph.nodes.filter { matches($0.id) }
            : graph.nodes
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
        guard let summary = sessions.first(where: { $0.id == sessionID }) else { return }
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
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escaped)\\""
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }

    func openInEditor(_ path: String) {
        // Falls back to whatever the user has associated with the folder.
        let url = URL(fileURLWithPath: path)
        for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
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
        NSWorkspace.shared.selectFile(summary.fileURL.path, inFileViewerRootedAtPath: summary.fileURL.deletingLastPathComponent().path)
    }

    /// Resumes a session in Terminal with `claude --resume <id>` in its own cwd.
    func resumeSession(_ summary: SessionSummary) {
        let path = summary.resolvedPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedPath)\\" && claude --resume \(summary.id)"
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
    }
}
