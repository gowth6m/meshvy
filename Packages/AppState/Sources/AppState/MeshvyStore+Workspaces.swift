import AppKit
import Foundation
import MeshvyModels

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
    public func createWorkspace(name: String, repos: [WorkspaceRepo], baseRef: String?, branch: String?) {
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

    public func addRepos(_ repos: [WorkspaceRepo]) {
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

    public func cloneRepos(_ references: [String], thenAddToActive: Bool) {
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
            detail: "The worktrees are untouched. Restore it from the workspace menu."
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
        guard var workspace = activeWorkspace else { return }
        workspace.repos.removeAll { $0.id == repoID }
        workspace.terminals.removeAll { $0.repoID == repoID }
        update(workspace)
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
