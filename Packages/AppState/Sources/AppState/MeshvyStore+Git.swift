import AppKit
import Foundation
import GitKit
import MeshvyModels

// Repository status and the diffs shown in the inspector.
extension MeshvyStore {
    // MARK: - Git

    public func refreshGitStatus() {
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
    public func openDiff(repoPath: String, change: FileChange) {
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

    public func closeDiff() {
        openFile = nil
        openDiff = nil
    }

    /// Changed files across every repository in the workspace.
    public var workspaceChanges: [(repo: WorkspaceRepo, files: [FileChange])] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.repos.compactMap { repo in
            let files = changes[repo.worktreePath] ?? []
            return files.isEmpty ? nil : (repo, files)
        }
    }

    public var totalChangedFiles: Int {
        workspaceChanges.reduce(0) { $0 + $1.files.count }
    }

    /// Every changed file in the workspace, in the inspector — which is what
    /// the workspace node's own panel is. Selected rather than revealed: the
    /// list is the point, and moving the board under you would not be.
    public func showWorkspaceChanges() {
        guard let id = activeWorkspace?.id else { return }
        inspectorVisible = true
        select(.workspace(id))
    }

    /// One repository's git state, or as much as is known before the first
    /// read of it lands.
    public func worktree(for repo: WorkspaceRepo) -> Worktree {
        if let read = worktrees[repo.worktreePath] { return read }
        return Worktree(
            path: repo.worktreePath,
            branch: activeWorkspace?.branch,
            head: nil,
            isMain: false,
            isDetached: false,
            isLocked: false,
            isPrunable: repo.failure != nil,
            isArchived: !FileManager.default.fileExists(atPath: repo.worktreePath),
            displayName: repo.name,
            failureReason: repo.failure
        )
    }
}
