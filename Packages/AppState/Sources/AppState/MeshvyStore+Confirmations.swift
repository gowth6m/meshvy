import AppKit
import Foundation
import MeshvyModels

// Anything that could lose work or stop an agent asks first.
extension MeshvyStore {
    // MARK: - Asking first
    //
    // What a button calls, as opposed to the plain verbs it ends in. Each one
    // decides whether the action is one you could regret — an agent stopped
    // mid-task, work taken off disk — and asks first if so. The quiet cases go
    // straight through: a shell closes on one click, and an idle board archives
    // without a question, because there is nothing either could cost you.

    /// Closes a terminal, asking first while an agent is running in it.
    public func requestClose(_ terminalID: UUID) {
        guard let workspace = activeWorkspace else { return }
        if workspace.orchestrator?.id == terminalID {
            requestStopCoordinator()
            return
        }
        guard let node = workspace.terminals.first(where: { $0.id == terminalID }),
              node.sessionID != nil, terminals.isRunning(terminalID) else {
            closeTerminal(terminalID)
            return
        }
        let working = activity(for: node)?.state == .working
        confirmation = Confirmation(
            title: "Stop “\(node.title)”?",
            message: (working ? "It is in the middle of a turn. " : "")
                + "Closing the terminal ends the agent. Its transcript stays on disk.",
            action: "Close and stop the agent",
            run: { [weak self] in self?.closeTerminal(terminalID) }
        )
    }

    /// Stops the coordinator, asking first while it is running.
    public func requestStopCoordinator() {
        guard isCoordinatorRunning, let workspace = activeWorkspace else {
            stopCoordinator()
            return
        }
        let working = workspace.orchestrator.flatMap { activity(for: $0) }?.state == .working
        confirmation = Confirmation(
            title: "Stop the coordinator?",
            message: (working ? "It is in the middle of a turn. " : "")
                + "The main chat for “\(workspace.name)” ends. Its threads keep running in their own terminals.",
            action: "Stop the coordinator",
            run: { [weak self] in self?.stopCoordinator() }
        )
    }

    /// Archives a workspace, asking first only when that would stop something.
    /// The toolbar button used to be the one path that asked; the menu item,
    /// ⌥⌘A and the palette stopped running agents without a word.
    public func requestArchive(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let running = workspace.allTerminals.filter { terminals.isRunning($0.id) }.count
        guard running > 0 else {
            archiveWorkspace(id)
            return
        }
        confirmation = Confirmation(
            title: "Archive “\(workspace.name)”?",
            message: "The worktrees and the branch are untouched. Restore it from the workspace menu.",
            action: "Archive and stop \(running) \(running == 1 ? "agent" : "agents")",
            run: { [weak self] in self?.archiveWorkspace(id) }
        )
    }

    /// The three ways to let go of a workspace, each asked about in its own
    /// words — what they cost you is exactly what differs between them. These
    /// sat one click deep in a context menu, and the last of them deletes the
    /// branch along with any commit that was never pushed.
    public func requestDelete(_ id: UUID, removeWorktrees: Bool, force: Bool) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let folder = workspace.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let delete: () -> Void = { [weak self] in
            self?.deleteWorkspace(id, removeWorktrees: removeWorktrees, force: force)
        }
        if !removeWorktrees {
            confirmation = Confirmation(
                title: "Close “\(workspace.name)”?",
                message: "Meshvy forgets it and stops its terminals. The worktrees stay in \(folder), "
                    + "but nothing here can reopen them — archive it instead to keep it one click away.",
                action: "Close",
                run: delete,
                alternative: ("Archive instead", { [weak self] in self?.archiveWorkspace(id) })
            )
        } else if !force {
            confirmation = Confirmation(
                title: "Delete the worktrees of “\(workspace.name)”?",
                message: "Every checkout in \(folder) is removed, and Meshvy forgets the workspace once "
                    + "they all are. One with uncommitted changes is kept and reported instead, and the "
                    + "branch \(workspace.branch) stays in every repository.",
                action: "Delete worktrees",
                run: delete
            )
        } else {
            confirmation = Confirmation(
                title: "Delete “\(workspace.name)” and discard its changes?",
                message: "Every checkout in \(folder) is removed, uncommitted work and all, and the branch "
                    + "\(workspace.branch) is deleted from each repository — commits that were never "
                    + "pushed go with it. This cannot be undone.",
                action: "Delete and discard changes",
                run: delete
            )
        }
    }

    /// Takes a repository out of the workspace, asking first when terminals are
    /// running in it, since they stop with it. Otherwise it goes straight away
    /// and the banner offers it back.
    public func requestRemoveRepo(_ repoID: String) {
        guard let workspace = activeWorkspace,
              let repo = workspace.repos.first(where: { $0.id == repoID }) else { return }
        let running = workspace.terminals.filter { $0.repoID == repoID && terminals.isRunning($0.id) }.count
        guard running > 0 else {
            removeRepo(repoID)
            return
        }
        confirmation = Confirmation(
            title: "Remove “\(repo.name)” from “\(workspace.name)”?",
            message: "\(running) \(running == 1 ? "terminal" : "terminals") running in it will stop. "
                + "The checkout stays on disk.",
            action: "Remove and stop \(running == 1 ? "it" : "them")",
            run: { [weak self] in self?.removeRepo(repoID) }
        )
    }

    func update(_ workspace: Workspace) {
        guard let position = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[position] = workspace
        persistWorkspaces()
        rebuild()
    }

    func persistWorkspaces() {
        workspaceStore.save(.init(workspaces: workspaces, activeWorkspaceID: activeWorkspaceID))
    }
}
