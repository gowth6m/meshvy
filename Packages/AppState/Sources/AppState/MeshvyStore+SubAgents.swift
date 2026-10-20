import AppKit
import Foundation

// Sub-agents the orchestrator dispatched with the Agent tool.
extension MeshvyStore {
    // MARK: - Sub-agents

    /// Re-reads the orchestrator's transcript for Agent-tool dispatches. Cheap
    /// enough to run on every transcript write while it is working.
    public func refreshSubAgents() {
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
    public func transcriptURL(for sessionID: String) -> URL? {
        indexer.transcriptFiles().first { $0.deletingPathExtension().lastPathComponent == sessionID }
    }

    public func closeTerminal(_ id: UUID) {
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

    public func restartTerminal(_ id: UUID) {
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

    /// Resizes the workspace node itself.
    ///
    /// Which height this sets depends on what is in the node: it collapses to a
    /// start prompt when no orchestrator is running, and the two states keep
    /// their own height. Without that, dragging the collapsed node taller wrote
    /// a number nothing read, and the node sprang back the moment you let go.
    public func resizeWorkspaceNode(to size: CGSize) {
        guard var workspace = activeWorkspace else { return }
        workspace.boardWidth = size.width
        if isOrchestratorRunning { workspace.boardHeight = size.height }
        else { workspace.idleBoardHeight = size.height }
        guard let position = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[position] = workspace
        if let node = graph.nodes.firstIndex(where: { $0.id == .workspace(workspace.id) }) {
            graph.nodes[node].size = size
            graph.nodes[node].kind = .workspace(workspace)
        }
    }

    public func moveTerminal(_ id: UUID, to position: CGPoint, size: CGSize? = nil) {
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

    public func commitTerminalMove() {
        persistWorkspaces()
        rebuild()
    }
}
