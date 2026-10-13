import AppKit
import Foundation
import MeshvyModels
import WorkspaceKit

// Creating, activating, archiving and deleting workspaces.
extension MeshvyStore {
    // MARK: - Creating a workspace

    /// Resolves picked folders into repositories we can cut worktrees from.
    public func inspectRepos(at paths: [String]) -> (repos: [WorkspaceRepo], rejected: [String]) {
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
    public func branches(for repos: [WorkspaceRepo]) -> [String] {
        builder.branches(for: repos)
    }

    /// Creates the workspace and its worktrees in one step: every repository
    /// gets a checkout of the same new branch under `~/.meshvy/<slug>/`.
    ///
    /// Remotes are cloned first and built in with the rest. The two used to
    /// run side by side, and whichever finished first decided where a clone
    /// went — one that beat the new workspace into existence was added to
    /// whichever workspace had been open before it. A workspace of nothing but
    /// URLs could not be created at all.
    public func createWorkspace(
        name: String, repos: [WorkspaceRepo], cloning remotes: [String] = [],
        baseRef: String?, branch: String?
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Workspace" : trimmed
        let branchName = (branch?.isEmpty == false ? branch! : Workspace.slug(resolved))
        let builder = self.builder

        isWorking = true
        show(.init(
            kind: .info,
            title: remotes.isEmpty
                ? "Creating worktrees in \(repos.count) repos…"
                : "Cloning \(remotes.count), then creating worktrees…",
            detail: nil
        ))

        Task.detached(priority: .userInitiated) {
            let clones = MeshvyStore.clone(remotes, with: builder)
            let all = repos + clones.repos.filter { clone in !repos.contains { $0.id == clone.id } }
            // Every clone failed and there was nothing else: no workspace,
            // rather than an empty one named after what could not be fetched.
            guard remotes.isEmpty || !all.isEmpty else {
                await MainActor.run { [weak self] in
                    self?.isWorking = false
                    self?.show(.init(
                        kind: .failure, title: "Nothing to create — the clone failed",
                        detail: clones.failures.joined(separator: "\n")
                    ))
                }
                return
            }
            let workspace = builder.build(name: resolved, branch: branchName, baseRef: baseRef, repos: all)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                self.workspaces.append(workspace)
                self.activeWorkspaceID = workspace.id
                self.persistWorkspaces()
                self.hasFitInitially = false
                self.loadActiveWorkspace()

                let failures = clones.failures + workspace.repos.compactMap { repo in
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
                        title: "\(workspace.readyRepos.count) of \(workspace.repos.count + clones.failures.count) worktrees created",
                        detail: failures.joined(separator: "\n")
                    ))
                }
            }
        }
    }

    /// Adds repositories to the open workspace, cloning any remotes first.
    public func addRepos(_ repos: [WorkspaceRepo], cloning remotes: [String] = []) {
        guard let workspace = activeWorkspace else { return }
        let builder = self.builder
        isWorking = true
        if !remotes.isEmpty { show(.init(kind: .info, title: "Cloning \(remotes.count)…", detail: nil)) }

        Task.detached(priority: .userInitiated) {
            let clones = MeshvyStore.clone(remotes, with: builder)
            let incoming = repos + clones.repos.filter { clone in !repos.contains { $0.id == clone.id } }
            let extended = builder.extend(workspace, with: incoming)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isWorking = false
                // Onto the workspace as it is now, not as it was when this
                // began: two adds in flight at once each wrote back their own
                // starting copy, and the later one dropped what the other had
                // just added.
                guard var current = self.workspaces.first(where: { $0.id == workspace.id }) else { return }
                let added = extended.repos.filter { repo in !current.repos.contains { $0.id == repo.id } }
                current.repos += added
                self.update(current)
                self.refreshGitStatus()
                if clones.failures.isEmpty {
                    self.show(.init(kind: .success, title: "Added \(added.count) to “\(workspace.name)”", detail: nil))
                } else {
                    self.show(.init(
                        kind: .failure,
                        title: "Added \(added.count) to “\(workspace.name)” — \(clones.failures.count) could not be cloned",
                        detail: clones.failures.joined(separator: "\n")
                    ))
                }
            }
        }
    }

    /// Clones each remote, sorting what came back into repositories and the
    /// reasons the rest did not.
    private nonisolated static func clone(
        _ remotes: [String], with builder: WorkspaceBuilder
    ) -> (repos: [WorkspaceRepo], failures: [String]) {
        var repos: [WorkspaceRepo] = []
        var failures: [String] = []
        for remote in remotes {
            switch builder.clone(remote) {
            case .cloned(let repo): repos.append(repo)
            case .failed(let message): failures.append("\(remote): \(message)")
            }
        }
        return (repos, failures)
    }

    public func activate(_ id: UUID) {
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
    public func archiveWorkspace(_ id: UUID) {
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
            detail: "The worktrees are untouched. Restore it from the workspace menu.",
            action: ("Undo", { [weak self] in self?.unarchiveWorkspace(id) })
        ))
    }

    /// Brings one back and opens it.
    public func unarchiveWorkspace(_ id: UUID) {
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
    public func deleteWorkspace(_ id: UUID, removeWorktrees: Bool, force: Bool) {
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

    func forget(_ id: UUID) {
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

    public func removeRepo(_ repoID: String) {
        guard var workspace = activeWorkspace,
              let position = workspace.repos.firstIndex(where: { $0.id == repoID }) else { return }
        let repo = workspace.repos[position]
        // Its terminals go with it, and so must their processes. Dropping the
        // nodes alone left their agents running with nothing on the board to
        // show for them, still editing a checkout you had just taken away.
        for terminal in workspace.terminals where terminal.repoID == repoID {
            terminals.discard(terminal.id)
            unread.remove(terminal.id)
            if let sessionID = terminal.sessionID { activity[sessionID] = nil }
        }
        workspace.repos.remove(at: position)
        workspace.terminals.removeAll { $0.repoID == repoID }
        update(workspace)
        notifier.badge(agentsNeedingYou.count)

        let workspaceID = workspace.id
        show(.init(
            kind: .success,
            title: "Removed “\(repo.name)” from “\(workspace.name)”",
            detail: "Its checkout is still at \(repo.worktreePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).",
            action: ("Undo", { [weak self] in self?.restoreRepo(repo, at: position, in: workspaceID) })
        ))
    }

    /// Puts a removed repository back where it was. The checkout never left
    /// the disk, so this is only the board remembering it again.
    func restoreRepo(_ repo: WorkspaceRepo, at position: Int, in workspaceID: UUID) {
        guard var workspace = activeWorkspace, workspace.id == workspaceID,
              !workspace.repos.contains(where: { $0.id == repo.id }) else { return }
        workspace.repos.insert(repo, at: min(position, workspace.repos.count))
        update(workspace)
        refreshGitStatus()
    }
}
