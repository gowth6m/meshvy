import AgentKit
import AppKit
import Foundation
import MeshvyCore
import MeshvyModels

// Bootstrap and the saved layout.
extension MeshvyStore {
    // MARK: - Lifecycle

    public func bootstrap() {
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
        checkClaudeInstalled()
        recheckClaudeOnActivation()
        // Quietly, on launch: only speaks up when there is something to take.
        updates.check()

        guard hasWorkspace else {
            statusLine = "No workspace — create one to get started"
            return
        }
        loadActiveWorkspace()
    }

    public func loadSavedLayout() {
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

    public func loadActiveWorkspace() {
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
}
