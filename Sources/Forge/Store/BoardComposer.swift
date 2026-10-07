import CoreGraphics
import Foundation

/// Decides what goes on the board for one workspace.
///
/// A workspace is the parent: its repositories are lanes beneath it, and
/// terminal nodes float freely where the user drops them. An orchestrator
/// terminal draws an edge to every repository so the parent/child shape the
/// workspace actually has is visible.
struct BoardComposer {
    struct Input {
        var workspace: Workspace
        /// Live git state keyed by the worktree path.
        var worktrees: [String: Worktree]
        var sessions: [SessionSummary]
        var statuses: [String: SessionStatus]
        var live: [String: LiveSession]
        var pinned: [String: CGPoint]
        /// Sessions already represented by a terminal node, so we do not draw
        /// a duplicate card for them.
        var claimedSessions: Set<String>
        var showEnded: Bool
    }

    private var gap: CGFloat { 20 }
    private var padding: CGFloat { 26 }
    private var headerHeight: CGFloat { 10 }
    private var sessionsPerLane: Int { 4 }

    func compose(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()
        let workspace = input.workspace

        // Attach sessions to the checkout they ran in.
        let index = PathIndex(paths: workspace.repos.map(\.worktreePath))
        var byRepo: [String: [SessionSummary]] = [:]
        for session in input.sessions {
            guard !input.claimedSessions.contains(session.id) else { continue }
            let status = input.statuses[session.id] ?? .ended
            guard input.showEnded || status.isLive else { continue }
            guard let path = index.owner(of: session.resolvedPath) else { continue }
            byRepo[path, default: []].append(session)
        }

        // One lane per repository.
        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []
        var y = headerHeight + padding
        var widestLane: CGFloat = Theme.worktreeNodeSize.width

        for repo in workspace.repos {
            let worktree = input.worktrees[repo.worktreePath] ?? Worktree(
                path: repo.worktreePath,
                branch: workspace.branch,
                head: nil,
                isMain: false,
                isDetached: false,
                isLocked: false,
                isPrunable: repo.failure != nil,
                isArchived: !FileManager.default.fileExists(atPath: repo.worktreePath),
                displayName: repo.name,
                failureReason: repo.failure
            )
            let nodeID = NodeID.worktree(repo.worktreePath)
            nodes.append(CanvasNode(
                id: nodeID,
                kind: .worktree(worktree),
                position: CGPoint(x: padding, y: y),
                size: Theme.worktreeNodeSize,
                sectionID: "workspace",
                repoID: repo.id
            ))

            let sessions = (byRepo[repo.worktreePath] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            var laneHeight = Theme.worktreeNodeSize.height
            let originX = padding + Theme.worktreeNodeSize.width + gap

            for (position, session) in sessions.enumerated() {
                let row = position / sessionsPerLane
                let column = position % sessionsPerLane
                let status = input.statuses[session.id] ?? .ended
                nodes.append(CanvasNode(
                    id: .session(session.id),
                    kind: .session(session, status: status, live: input.live[session.id]),
                    position: CGPoint(
                        x: originX + CGFloat(column) * (Theme.sessionNodeSize.width + gap),
                        y: y + CGFloat(row) * (Theme.sessionNodeSize.height + gap)
                    ),
                    size: Theme.sessionNodeSize,
                    sectionID: "workspace",
                    repoID: repo.id
                ))
                edges.append(CanvasEdge(from: .session(session.id), to: nodeID, isLive: status.isLive))
                laneHeight = max(laneHeight, CGFloat(row + 1) * (Theme.sessionNodeSize.height + gap) - gap)
                widestLane = max(
                    widestLane,
                    Theme.worktreeNodeSize.width + gap
                        + CGFloat(min(sessions.count, sessionsPerLane)) * (Theme.sessionNodeSize.width + gap) - gap
                )
            }
            y += laneHeight + gap
        }

        let sectionSize = CGSize(
            width: widestLane + padding * 2,
            height: max(y - gap + padding, Theme.worktreeNodeSize.height + padding * 2 + headerHeight)
        )
        graph.groups.append(CanvasGroup(
            id: "workspace",
            kind: .workspace,
            title: workspace.name,
            subtitle: workspace.branch + "  ·  " + workspace.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            rect: CGRect(origin: .zero, size: sectionSize),
            seed: workspace.branch
        ))
        graph.nodes = nodes
        graph.edges = edges

        // Terminals float where they were dropped; a fresh one is parked to the
        // right of the workspace so it never lands on top of the repositories.
        var terminalOrigin = CGPoint(x: sectionSize.width + 70, y: 0)
        for terminal in workspace.terminals {
            var position = terminal.position
            if position == .zero {
                position = terminalOrigin
                terminalOrigin.y += terminal.size.height + 28
            }
            graph.nodes.append(CanvasNode(
                id: .terminal(terminal.id),
                kind: .terminal(terminal),
                position: position,
                size: terminal.size,
                sectionID: nil,
                repoID: terminal.repoID
            ))

            // An orchestrator owns every repository; a repo terminal owns one.
            switch terminal.role {
            case .orchestrator:
                for repo in workspace.readyRepos {
                    graph.edges.append(CanvasEdge(
                        from: .terminal(terminal.id),
                        to: .worktree(repo.worktreePath),
                        isLive: true,
                        kind: .owns
                    ))
                }
            case .repo, .shell:
                if let repoID = terminal.repoID,
                   let repo = workspace.repos.first(where: { $0.id == repoID }) {
                    graph.edges.append(CanvasEdge(
                        from: .terminal(terminal.id),
                        to: .worktree(repo.worktreePath),
                        isLive: true,
                        kind: .owns
                    ))
                }
            }
        }

        applyPinned(&graph, pinned: input.pinned)
        return graph
    }

    private func applyPinned(_ graph: inout CanvasGraph, pinned: [String: CGPoint]) {
        guard !pinned.isEmpty else { return }
        for (offset, node) in graph.nodes.enumerated() {
            // Terminals carry their own saved position on the model.
            if case .terminal = node.kind { continue }
            guard let position = pinned[node.id.storageKey] else { continue }
            graph.nodes[offset].position = position
            graph.nodes[offset].isPinned = true
        }
    }
}

enum GroupKind {
    case workspace
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
