import AppKit
import Foundation
import MeshvyModels
import PersistenceKit

// Composing the canvas graph, hit-testing it, and the links between nodes.
extension MeshvyStore {
    // MARK: - Graph

    func rebuild() {
        guard let workspace = activeWorkspace else {
            graph = CanvasGraph()
            return
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: allSessions.map { ($0.id, live[$0.id]?.status ?? .ended) }
        )
        graph = composer.compose(.init(
            workspace: workspace,
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
        if let selection, boardNode(for: selection) == nil { self.selection = nil }
    }

    /// The node on the board that shows `id`. A repository has no node of its
    /// own — it is a chip on the workspace node — so that is where it is drawn,
    /// for as long as it is still part of the workspace.
    public func boardNode(for id: NodeID) -> CanvasNode? {
        guard case .worktree(let path) = id else { return graph.node(id) }
        guard let workspace = activeWorkspace,
              workspace.repos.contains(where: { $0.worktreePath == path }) else { return nil }
        return graph.node(.workspace(workspace.id))
    }

    func recomputeMatches() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { matchingNodes = []; return }
        let terms = query.split(separator: " ").map(String.init)
        matchingNodes = Set(
            graph.nodes
                .filter { node in terms.allSatisfy { node.searchText.contains($0) } }
                .map { $0.id.storageKey }
        )
    }

    public var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func matches(_ id: NodeID) -> Bool { matchingNodes.contains(id.storageKey) }

    func summaryLine() -> String {
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

    public func show(_ banner: Banner) {
        self.banner = banner
        let id = banner.id
        Task {
            try? await Task.sleep(for: .seconds(banner.kind == .failure ? 12 : 4))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    public func dismissBanner() { banner = nil }

    // MARK: - Interaction

    public func select(_ id: NodeID?) {
        selection = id
        markRead(id)
        guard case .session(let sessionID)? = id else { return }
        loadTranscript(sessionID)
    }

    public func moveNode(_ id: NodeID, to position: CGPoint) {
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

    public func commitMove() { persistLayout(); persistWorkspaces() }

    // MARK: - Links
    //
    // Every other edge on the board is derived: a terminal owns the checkout it
    // runs in, the orchestrator dispatched the agent it spawned. A link is the
    // one the board cannot work out, so it is stored on the workspace — and,
    // when the far end is an agent that is running, delivered to it.

    /// Draws a link, and hands the target whatever the source is.
    public func link(from: NodeID, to: NodeID) {
        guard from != to, var workspace = activeWorkspace else { return }
        let link = WorkspaceLink(from: from, to: to)
        guard !workspace.links.contains(where: { $0.id == link.id }) else { return }
        workspace.links.append(link)
        update(workspace)
        deliverContext(for: link, in: workspace)
    }

    public func unlink(from: NodeID, to: NodeID) {
        guard var workspace = activeWorkspace else { return }
        let id = WorkspaceLink(from: from, to: to).id
        workspace.links.removeAll { $0.id == id }
        update(workspace)
    }

    /// Links either end of which is this node.
    public func links(touching id: NodeID) -> [WorkspaceLink] {
        (activeWorkspace?.links ?? []).filter { $0.from == id || $0.to == id }
    }

    /// Says what the source is to the target's own session.
    ///
    /// This is what a link is *for*: two agents that would otherwise have to be
    /// told about each other by hand now share a frame of reference. A target
    /// that is not a running agent keeps the line on the board and nothing
    /// more — it is still a note to you about how the work fits together.
    func deliverContext(for link: WorkspaceLink, in workspace: Workspace) {
        guard let brief = contextBrief(for: link.from, in: workspace) else { return }
        // Only an agent is told. A plain shell has no one reading it — typing a
        // paragraph of prose at a bash prompt would just be a failed command —
        // and anything not running yet will be started with its own brief.
        guard let target = terminalNode(for: link.to),
              target.sessionID != nil,
              terminals.isRunning(target.id) else {
            show(.init(
                kind: .info,
                title: "Linked",
                detail: "No agent is running at the other end, so the line is on the board and nothing was sent."
            ))
            return
        }
        _ = send(brief, to: target, saying: "take context from the node you linked it to")
    }

    /// The terminal a node id stands for, if it is one at all.
    func terminalNode(for id: NodeID) -> TerminalNode? {
        guard let workspace = activeWorkspace else { return nil }
        switch id {
        case .terminal(let uuid): return workspace.terminals.first { $0.id == uuid }
        case .workspace: return workspace.orchestrator
        default: return nil
        }
    }

    /// One paragraph describing a node, in the terms an agent can act on: where
    /// it is on disk, and what it is doing there.
    func contextBrief(for id: NodeID, in workspace: Workspace) -> String? {
        switch id {
        case .terminal, .workspace:
            guard let node = terminalNode(for: id) else { return nil }
            var lines = ["Context: another agent in this workspace, `\(node.title)`, is working in `\(node.cwd)`."]
            if let task = node.openingTask, !task.isEmpty {
                lines.append("It was asked to: \(task)")
            } else if let message = activity(for: node)?.message, !message.isEmpty {
                lines.append("It is currently: \(message)")
            }
            lines.append("Read what it has changed there before you touch the same files, and coordinate rather than duplicating its work.")
            return lines.joined(separator: " ")
        case .worktree(let path):
            let name = workspace.repos.first { $0.worktreePath == path }?.name
                ?? URL(fileURLWithPath: path).lastPathComponent
            return "Context: the repository `\(name)` is checked out at `\(path)` on branch `\(workspace.branch)`. Treat it as in scope for this task."
        case .browser(let uuid):
            guard let browser = workspace.browsers.first(where: { $0.id == uuid }) else { return nil }
            return "Context: a browser on the board is open at \(browser.url). You can drive it with the `browser_*` tools."
        case .session(let sessionID):
            guard let summary = allSessions.first(where: { $0.id == sessionID }) else { return nil }
            return "Context: an earlier Claude Code session in `\(summary.resolvedPath)` worked on: \(summary.displayTitle). Its transcript id is \(sessionID)."
        case .subAgent(let agentID):
            guard let agent = subAgents.first(where: { $0.id == agentID }) else { return nil }
            return "Context: a sub-agent (`\(agent.kind)`) was dispatched to: \(agent.prompt)"
        }
    }

    public func resetLayout() {
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

    public func persistLayout() {
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
}
