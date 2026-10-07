import Foundation

/// Decides what goes on the board and how it is grouped.
///
/// The layout engine only positions sections and lanes; everything about what a
/// section *means* — a link, a repo's main checkout, history whose directory is
/// gone — is decided here.
struct BoardComposer {
    enum Grouping: String, Codable, CaseIterable, Hashable {
        /// Group by link: one section per linked branch spanning repos.
        case link
        /// Group by repository, with its worktrees as lanes.
        case repo

        var label: String {
            switch self {
            case .link: return "Linked worktrees"
            case .repo: return "Repositories"
            }
        }

        var icon: String {
            switch self {
            case .link: return "link"
            case .repo: return "shippingbox"
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

        var sections = input.grouping == .link
            ? linkSections(input, worktrees: allWorktrees, sessions: byPath)
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

    // MARK: - Grouped by link

    private func linkSections(
        _ input: Input, worktrees: [Worktree], sessions: [String: [SessionSummary]]
    ) -> [BoardSection] {
        var claimed = Set<String>()
        var sections: [BoardSection] = []

        for link in input.workspace.linkedWorktrees.sorted(by: { $0.createdAt > $1.createdAt }) {
            var lanes: [BoardLane] = []
            for checkout in link.checkouts {
                claimed.insert(checkout.path)
                let existing = worktrees.first { $0.path == checkout.path }
                let worktree = existing ?? Worktree(
                    path: checkout.path,
                    branch: link.branch,
                    head: nil,
                    isMain: false,
                    isDetached: false,
                    isLocked: false,
                    // A checkout whose `git worktree add` failed, or that has since
                    // been removed on disk, still earns a card saying so.
                    isPrunable: checkout.failure != nil,
                    isArchived: !FileManager.default.fileExists(atPath: checkout.path),
                    displayName: checkout.repoName
                )
                lanes.append(BoardLane(worktree: worktree, sessions: sessions[checkout.path] ?? []))
            }
            sections.append(BoardSection(
                id: "link." + link.id.uuidString,
                kind: .link,
                title: link.name,
                subtitle: link.intent ?? link.branch,
                seed: link.branch,
                lanes: lanes,
                linkID: link.id,
                branch: link.branch
            ))
        }

        // The repos themselves, so the workspace is visible before any link exists.
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
                subtitle: "Not part of a link",
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
    var linkID: UUID?
    var branch: String?

    var sessionCount: Int { lanes.reduce(0) { $0 + $1.sessions.count } }
}

/// A worktree and the sessions that ran in it.
struct BoardLane {
    var worktree: Worktree?
    var sessions: [SessionSummary]
}

enum GroupKind {
    case link
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
