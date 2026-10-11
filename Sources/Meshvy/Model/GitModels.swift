import Foundation

/// A checkout on disk — either a repository's main working tree or a linked worktree.
struct Worktree: Identifiable, Hashable {
    var path: String
    var branch: String?
    var head: String?
    var isMain: Bool
    var isDetached: Bool
    var isLocked: Bool
    var isPrunable: Bool
    /// Reconstructed from session history: the directory is gone and git no
    /// longer tracks it, but transcripts from it survive.
    var isArchived: Bool = false
    /// Overrides `name` for synthesized lanes.
    var displayName: String?
    /// Why this checkout could not be created, when it could not.
    var failureReason: String?

    // Filled in by a second, slower pass so the canvas can draw immediately.
    var dirtyFiles: Int?
    var untrackedFiles: Int?
    var ahead: Int?
    var behind: Int?
    var upstream: String?
    var lastCommitSubject: String?
    var lastCommitDate: Date?
    var lastCommitAuthor: String?

    var id: String { path }
    var name: String { displayName ?? URL(fileURLWithPath: path).lastPathComponent }

    var branchLabel: String {
        if let branch, !branch.isEmpty { return branch }
        if isDetached, let head { return String(head.prefix(7)) + " (detached)" }
        return "—"
    }

    var isDirty: Bool { (dirtyFiles ?? 0) + (untrackedFiles ?? 0) > 0 }
    var hasStatus: Bool { dirtyFiles != nil }
    var existsOnDisk: Bool { !isArchived && !isPrunable }
}

/// A repository, identified by its shared git directory so every linked
/// worktree folds into one group.
struct Repo: Identifiable, Hashable {
    /// Resolved `--git-common-dir`; stable across all worktrees of the repo.
    var commonDir: String
    var mainPath: String
    var worktrees: [Worktree]

    var id: String { commonDir }
    var name: String { URL(fileURLWithPath: mainPath).lastPathComponent }

    func worktree(containing path: String) -> Worktree? {
        // Longest-prefix match so nested paths pick the most specific worktree.
        worktrees
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}
