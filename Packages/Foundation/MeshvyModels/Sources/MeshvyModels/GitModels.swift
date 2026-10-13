import Foundation

/// A checkout on disk — either a repository's main working tree or a linked worktree.
public struct Worktree: Identifiable, Hashable {
    public var path: String
    public var branch: String?
    public var head: String?
    public var isMain: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    /// Reconstructed from session history: the directory is gone and git no
    /// longer tracks it, but transcripts from it survive.
    public var isArchived: Bool = false
    /// Overrides `name` for synthesized lanes.
    public var displayName: String?
    /// Why this checkout could not be created, when it could not.
    public var failureReason: String?

    // Filled in by a second, slower pass so the canvas can draw immediately.
    public var dirtyFiles: Int?
    public var untrackedFiles: Int?
    public var ahead: Int?
    public var behind: Int?
    public var upstream: String?
    public var lastCommitSubject: String?
    public var lastCommitDate: Date?
    public var lastCommitAuthor: String?

    public init(
        path: String,
        branch: String? = nil,
        head: String? = nil,
        isMain: Bool,
        isDetached: Bool,
        isLocked: Bool,
        isPrunable: Bool,
        isArchived: Bool = false,
        displayName: String? = nil,
        failureReason: String? = nil,
        dirtyFiles: Int? = nil,
        untrackedFiles: Int? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        upstream: String? = nil,
        lastCommitSubject: String? = nil,
        lastCommitDate: Date? = nil,
        lastCommitAuthor: String? = nil
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.isArchived = isArchived
        self.displayName = displayName
        self.failureReason = failureReason
        self.dirtyFiles = dirtyFiles
        self.untrackedFiles = untrackedFiles
        self.ahead = ahead
        self.behind = behind
        self.upstream = upstream
        self.lastCommitSubject = lastCommitSubject
        self.lastCommitDate = lastCommitDate
        self.lastCommitAuthor = lastCommitAuthor
    }

    public var id: String { path }
    public var name: String { displayName ?? URL(fileURLWithPath: path).lastPathComponent }

    public var branchLabel: String {
        if let branch, !branch.isEmpty { return branch }
        if isDetached, let head { return String(head.prefix(7)) + " (detached)" }
        return "—"
    }

    public var isDirty: Bool { (dirtyFiles ?? 0) + (untrackedFiles ?? 0) > 0 }
    public var hasStatus: Bool { dirtyFiles != nil }
    public var existsOnDisk: Bool { !isArchived && !isPrunable }
}

/// A repository, identified by its shared git directory so every linked
/// worktree folds into one group.
public struct Repo: Identifiable, Hashable {
    /// Resolved `--git-common-dir`; stable across all worktrees of the repo.
    public var commonDir: String
    public var mainPath: String
    public var worktrees: [Worktree]

    public init(
        commonDir: String,
        mainPath: String,
        worktrees: [Worktree]
    ) {
        self.commonDir = commonDir
        self.mainPath = mainPath
        self.worktrees = worktrees
    }

    public var id: String { commonDir }
    public var name: String { URL(fileURLWithPath: mainPath).lastPathComponent }

    public func worktree(containing path: String) -> Worktree? {
        // Longest-prefix match so nested paths pick the most specific worktree.
        worktrees
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }
}
