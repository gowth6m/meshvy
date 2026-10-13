import AppKit
import FileSystemKit
import Foundation
import MeshvyModels

// Reading Claude's own session files: the index, live sessions, watchers, transcripts.
extension MeshvyStore {
    // MARK: - Indexing

    func startIndexing(files: [URL], quiet: Bool = false) {
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

    func merge(_ batch: [SessionSummary]) {
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

    func reindexChangedTranscripts() {
        guard hasWorkspace, !isIndexing else { return }
        startIndexing(files: indexer.transcriptFiles(), quiet: true)
    }

    public func refreshAll() {
        guard hasWorkspace else { return }
        statusLine = "Refreshing…"
        refreshLive(rebuildGraph: false)
        startIndexing(files: indexer.transcriptFiles())
        refreshGitStatus()
    }

    // MARK: - Live sessions

    public func refreshLive(rebuildGraph: Bool = true) {
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

    func startWatching() {
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

    func startTimers() {
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

    // MARK: - Transcript

    func loadTranscript(_ sessionID: String) {
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

    public func reloadTranscript() {
        guard let id = transcriptSessionID else { return }
        transcriptSessionID = nil
        loadTranscript(id)
    }
}
