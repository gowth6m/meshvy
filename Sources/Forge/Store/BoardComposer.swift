import Foundation

/// Decides what goes on the board and how it is grouped.
///
/// The layout engine only positions sections and lanes; everything about what a
/// section *means* — a stack, a repo's main checkout, history whose directory is
/// gone — is decided here.
struct BoardComposer {
    enum Grouping: String, Codable, CaseIterable {
        /// Group by stack: one section per linked branch spanning repos.
        case stack
        /// Group by repository, with its worktrees as lanes.
        case repo

        var label: String {
            switch self {
            case .stack: return "By stack"
            case .repo: return "By repo"
            }
        }
    }

    struct Input {
        var workspace: Workspace
        /// Live git state for the workspace's repos, keyed by repo id.
        var worktreesByRepo: [String: [Worktree]]
        var sessions: [SessionSummary]
        var grouping: Grouping
    }

    func compose(_ input: Input) -> [BoardSection] {
        let allWorktrees = input.worktreesByRepo.values.flatMap { $0 }
        let index = PathIndex(paths: allWorktrees.map(\.path))

        // Attach every session to the checkout it ran in.
        var byPath: [String: [SessionSummary]] = [:]
        var orphans: [SessionSummary] = []
        for session in input.sessions {
            if let path = index.owner(of: session.resolvedPath) {
                byPath[path, default: []].append(session)
            } else {
                orphans.append(session)
            }
        }

        var sections = input.grouping == .stack
            ? stackSections(input, worktrees: allWorktrees, sessions: byPath)
            : repoSections(input, sessions: byPath)

        if !orphans.isEmpty {
            sections.append(BoardSection(
                id: "forge.archived",
                kind: .archived,
                title: "Archived",
                subtitle: "Sessions whose checkout is gone",
                seed: "archived",
                lanes: [BoardLane(worktree: nil, sessions: orphans)]
            ))
        }
        return sections
    }

    // MARK: - Grouped by stack

    private func stackSections(
        _ input: Input, worktrees: [Worktree], sessions: [String: [SessionSummary]]
    ) -> [BoardSection] {
        var claimed = Set<String>()
        var sections: [BoardSection] = []

        for stack in input.workspace.stacks.sorted(by: { $0.createdAt > $1.createdAt }) {
            var lanes: [BoardLane] = []
            for member in stack.members {
                claimed.insert(member.path)
                let existing = worktrees.first { $0.path == member.path }
                let worktree = existing ?? Worktree(
                    path: member.path,
                    branch: stack.branch,
                    head: nil,
                    isMain: false,
                    isDetached: false,
                    isLocked: false,
                    // A member whose `git worktree add` failed, or that has since
                    // been removed on disk, still earns a card saying so.
                    isPrunable: member.failure != nil,
                    isArchived: !FileManager.default.fileExists(atPath: member.path),
                    displayName: member.repoName
                )
                lanes.append(BoardLane(worktree: worktree, sessions: sessions[member.path] ?? []))
            }
            sections.append(BoardSection(
                id: "stack." + stack.id.uuidString,
                kind: .stack,
                title: stack.name,
                subtitle: stack.intent ?? stack.branch,
                seed: stack.branch,
                lanes: lanes,
                stackID: stack.id,
                branch: stack.branch
            ))
        }

        // The repos themselves, so the workspace is visible before any stack exists.
        var mainLanes: [BoardLane] = []
        var otherLanes: [BoardLane] = []
        for repo in input.workspace.repos {
            for worktree in input.worktreesByRepo[repo.id] ?? [] {
                guard !claimed.contains(worktree.path) else { continue }
                let lane = BoardLane(worktree: worktree, sessions: sessions[worktree.path] ?? [])
                if worktree.isMain { mainLanes.append(lane) } else { otherLanes.append(lane) }
            }
        }

        if !mainLanes.isEmpty {
            sections.insert(BoardSection(
                id: "forge.main",
                kind: .main,
                title: input.workspace.name,
                subtitle: "\(mainLanes.count) repositories",
                seed: input.workspace.id.uuidString,
                lanes: mainLanes
            ), at: 0)
        }
        if !otherLanes.isEmpty {
            sections.append(BoardSection(
                id: "forge.other",
                kind: .other,
                title: "Other worktrees",
                subtitle: "Not part of a stack",
                seed: "other",
                lanes: otherLanes.sorted { ($0.worktree?.name ?? "") < ($1.worktree?.name ?? "") }
            ))
        }
        return sections
    }

    // MARK: - Grouped by repository

    private func repoSections(_ input: Input, sessions: [String: [SessionSummary]]) -> [BoardSection] {
        input.workspace.repos.map { repo in
            let worktrees = (input.worktreesByRepo[repo.id] ?? []).sorted { lhs, rhs in
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return BoardSection(
                id: "repo." + repo.id,
                kind: .repo,
                title: repo.name,
                subtitle: repo.path,
                seed: repo.id,
                lanes: worktrees.map { BoardLane(worktree: $0, sessions: sessions[$0.path] ?? []) }
            )
        }
    }
}

/// One container on the board.
struct BoardSection: Identifiable {
    var id: String
    var kind: GroupKind
    var title: String
    var subtitle: String
    var seed: String
    var lanes: [BoardLane]
    var stackID: UUID?
    var branch: String?

    var sessionCount: Int { lanes.reduce(0) { $0 + $1.sessions.count } }
}

/// A worktree and the sessions that ran in it.
struct BoardLane {
    var worktree: Worktree?
    var sessions: [SessionSummary]
}

enum GroupKind {
    case stack
    case main
    case other
    case repo
    case archived
}

/// Longest-prefix path ownership, with symlinks resolved.
///
/// The CLI records `cwd` after resolving symlinks (`/tmp` comes back as
/// `/private/tmp`), so comparing raw strings silently fails to attach sessions.
struct PathIndex {
    private let canonical: [(canonical: String, original: String)]

    init(paths: [String]) {
        canonical = paths
            .map { (PathIndex.canonicalize($0), $0) }
            .sorted { $0.0.count > $1.0.count }
    }

    func owner(of path: String) -> String? {
        let target = PathIndex.canonicalize(path)
        return canonical.first { target == $0.canonical || target.hasPrefix($0.canonical + "/") }?.original
    }

    static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
