import CoreGraphics
import Foundation

/// Deterministic auto-layout for the board.
///
/// Repositories become containers; inside each one every worktree gets a lane
/// with its sessions flowing to the right of it. Groups are sized to their
/// content and shelf-packed, so a repo with one session stays small instead of
/// reserving a full-width slot. Nodes the user has dragged keep their saved
/// position, so a hand-arranged board survives a refresh.
struct BoardLayout {
    var gap: CGFloat = 20
    var groupPadding: CGFloat = 24
    /// Breathing room inside the container; the group's label is drawn above it.
    var groupHeaderHeight: CGFloat = 8
    var groupSpacing: CGFloat = 70
    /// Bounds on how many sessions sit beside a worktree before wrapping. The
    /// actual figure is chosen per group from its busiest lane, so a repo with
    /// forty archived sessions spreads sideways instead of becoming a tall
    /// column that forces the whole board to zoom out.
    var minSessionsPerLane: Int = 3
    var maxSessionsPerLane: Int = 8
    /// Shelf width before groups wrap to a new row.
    var maxRowWidth: CGFloat = 5400

    private var sessionSize: CGSize { Theme.sessionNodeSize }
    private var worktreeSize: CGSize { Theme.worktreeNodeSize }

    struct Input {
        var repos: [Repo]
        var sessions: [SessionSummary]
        var attachment: [String: String]
        var unattached: [SessionSummary]
        var statuses: [String: SessionStatus]
        var live: [String: LiveSession]
        var pinned: [String: CGPoint]
        var groupByRepo: Bool
    }

    func build(_ input: Input) -> CanvasGraph {
        input.groupByRepo ? grouped(input) : flat(input)
    }

    // MARK: - Grouped by repository

    private func grouped(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()

        var byWorktree: [String: [SessionSummary]] = [:]
        for session in input.sessions {
            guard let path = input.attachment[session.id] else { continue }
            byWorktree[path, default: []].append(session)
        }

        // Live work first, then most recently touched.
        let ordered = input.repos.sorted { lhs, rhs in
            let lhsLive = liveCount(lhs, byWorktree, input.statuses)
            let rhsLive = liveCount(rhs, byWorktree, input.statuses)
            if lhsLive != rhsLive { return lhsLive > rhsLive }
            return recency(lhs, byWorktree) > recency(rhs, byWorktree)
        }

        var blocks: [GroupBlock] = ordered.map { repo in
            layoutGroup(
                id: repo.id,
                title: repo.name,
                subtitle: repo.mainPath,
                seed: repo.id,
                lanes: orderedWorktrees(repo, byWorktree).map { worktree in
                    Lane(worktree: worktree, sessions: byWorktree[worktree.path] ?? [])
                },
                input: input
            )
        }

        if !input.unattached.isEmpty {
            blocks.append(layoutGroup(
                id: "forge.unattached",
                title: "Unattached sessions",
                subtitle: "No matching repository on disk",
                seed: "unattached",
                lanes: [Lane(worktree: nil, sessions: input.unattached)],
                input: input
            ))
        }

        place(blocks: blocks, into: &graph)
        applyPinned(&graph, pinned: input.pinned)
        return graph
    }

    /// Shelf packing: fill a row left to right, wrap when the next group would
    /// overflow, and start each row below the tallest group of the previous one.
    private func place(blocks: [GroupBlock], into graph: inout CanvasGraph) {
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0

        for block in blocks {
            if origin.x > 0, origin.x + block.size.width > maxRowWidth {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + groupSpacing)
                rowHeight = 0
            }
            graph.groups.append(CanvasGroup(
                id: block.id,
                title: block.title,
                subtitle: block.subtitle,
                rect: CGRect(origin: origin, size: block.size),
                seed: block.seed
            ))
            for node in block.nodes {
                var moved = node
                moved.position = CGPoint(x: node.position.x + origin.x, y: node.position.y + origin.y)
                graph.nodes.append(moved)
            }
            graph.edges.append(contentsOf: block.edges)

            rowHeight = max(rowHeight, block.size.height)
            origin.x += block.size.width + groupSpacing
        }
    }

    private struct Lane {
        var worktree: Worktree?
        var sessions: [SessionSummary]
    }

    /// A laid-out group with node positions relative to its own origin, so the
    /// packer can place it without redoing the interior.
    private struct GroupBlock {
        var id: String
        var title: String
        var subtitle: String
        var seed: String
        var size: CGSize
        var nodes: [CanvasNode]
        var edges: [CanvasEdge]
    }

    private func layoutGroup(
        id: String, title: String, subtitle: String, seed: String,
        lanes: [Lane], input: Input
    ) -> GroupBlock {
        let hasWorktreeCards = lanes.contains { $0.worktree != nil }
        let busiestLane = lanes.map(\.sessions.count).max() ?? 0
        let squarish = Int(Double(busiestLane).squareRoot().rounded(.up))
        let perRow = min(maxSessionsPerLane, max(minSessionsPerLane, squarish))

        // Width is driven by the busiest lane, so quiet repos stay compact.
        let widestLane = lanes.map { min($0.sessions.count, perRow) }.max() ?? 0
        let sessionColumns = CGFloat(widestLane)
        var contentWidth: CGFloat = hasWorktreeCards ? worktreeSize.width : 0
        if sessionColumns > 0 {
            if hasWorktreeCards { contentWidth += gap }
            contentWidth += sessionColumns * (sessionSize.width + gap) - gap
        }
        contentWidth = max(contentWidth, worktreeSize.width)

        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []
        var y = groupHeaderHeight + groupPadding
        let laneX = groupPadding

        for lane in lanes {
            let sessions = lane.sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
            var laneHeight: CGFloat = 0
            var worktreeID: NodeID?

            if let worktree = lane.worktree {
                let nodeID = NodeID.worktree(worktree.path)
                worktreeID = nodeID
                nodes.append(CanvasNode(
                    id: nodeID,
                    kind: .worktree(worktree),
                    position: CGPoint(x: laneX, y: y),
                    size: worktreeSize,
                    repoID: id
                ))
                laneHeight = worktreeSize.height
            }

            let sessionOriginX = lane.worktree == nil ? laneX : laneX + worktreeSize.width + gap
            for (position, session) in sessions.enumerated() {
                let row = position / perRow
                let col = position % perRow
                let nodeID = NodeID.session(session.id)
                let status = input.statuses[session.id] ?? .ended
                nodes.append(CanvasNode(
                    id: nodeID,
                    kind: .session(session, status: status, live: input.live[session.id]),
                    position: CGPoint(
                        x: sessionOriginX + CGFloat(col) * (sessionSize.width + gap),
                        y: y + CGFloat(row) * (sessionSize.height + gap)
                    ),
                    size: sessionSize,
                    repoID: id
                ))
                if let worktreeID {
                    edges.append(CanvasEdge(from: nodeID, to: worktreeID, isLive: status.isLive))
                }
                laneHeight = max(laneHeight, CGFloat(row + 1) * (sessionSize.height + gap) - gap)
            }

            y += laneHeight + gap
        }

        let size = CGSize(
            width: contentWidth + groupPadding * 2,
            height: max(y - gap + groupPadding, groupHeaderHeight + groupPadding * 2 + worktreeSize.height)
        )
        return GroupBlock(
            id: id, title: title, subtitle: subtitle, seed: seed,
            size: size, nodes: nodes, edges: edges
        )
    }

    // MARK: - Flat grid

    private func flat(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()
        let columns = 7
        var items: [(NodeID, NodeKind, CGSize, Date)] = []

        for repo in input.repos {
            for worktree in repo.worktrees where !worktree.isArchived {
                items.append((
                    .worktree(worktree.path), .worktree(worktree),
                    worktreeSize, worktree.lastCommitDate ?? .distantPast
                ))
            }
        }
        for session in input.sessions {
            let status = input.statuses[session.id] ?? .ended
            items.append((
                .session(session.id),
                .session(session, status: status, live: input.live[session.id]),
                sessionSize, session.lastActivityAt
            ))
        }
        items.sort { $0.3 > $1.3 }

        let cellWidth = sessionSize.width + gap
        let cellHeight = sessionSize.height + gap
        for (position, item) in items.enumerated() {
            graph.nodes.append(CanvasNode(
                id: item.0,
                kind: item.1,
                position: CGPoint(
                    x: CGFloat(position % columns) * cellWidth,
                    y: CGFloat(position / columns) * cellHeight
                ),
                size: item.2,
                repoID: nil
            ))
        }

        applyPinned(&graph, pinned: input.pinned)
        return graph
    }

    // MARK: - Shared

    private func applyPinned(_ graph: inout CanvasGraph, pinned: [String: CGPoint]) {
        guard !pinned.isEmpty else { return }
        for (offset, node) in graph.nodes.enumerated() {
            guard let position = pinned[node.id.storageKey] else { continue }
            graph.nodes[offset].position = position
            graph.nodes[offset].isPinned = true
        }
    }

    /// Main worktree first, then busiest, with the archived lane always last.
    private func orderedWorktrees(_ repo: Repo, _ sessions: [String: [SessionSummary]]) -> [Worktree] {
        repo.worktrees.sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return rhs.isArchived }
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            let lhsDate = sessions[lhs.path]?.map(\.lastActivityAt).max() ?? lhs.lastCommitDate ?? .distantPast
            let rhsDate = sessions[rhs.path]?.map(\.lastActivityAt).max() ?? rhs.lastCommitDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func recency(_ repo: Repo, _ sessions: [String: [SessionSummary]]) -> Date {
        var newest = Date.distantPast
        for worktree in repo.worktrees {
            if let date = sessions[worktree.path]?.map(\.lastActivityAt).max(), date > newest { newest = date }
            if let date = worktree.lastCommitDate, date > newest { newest = date }
        }
        return newest
    }

    private func liveCount(
        _ repo: Repo, _ sessions: [String: [SessionSummary]], _ statuses: [String: SessionStatus]
    ) -> Int {
        repo.worktrees.reduce(0) { total, worktree in
            total + (sessions[worktree.path] ?? []).filter { statuses[$0.id]?.isLive == true }.count
        }
    }
}

/// Longest-prefix lookup from an arbitrary path to the worktree that contains it.
struct WorktreeIndex {
    private let paths: [String]

    init(repos: [Repo]) {
        // Longest first so the first match is the most specific worktree.
        paths = repos
            .flatMap { $0.worktrees }
            .filter { !$0.isArchived }
            .map(\.path)
            .sorted { $0.count > $1.count }
    }

    func worktreePath(containing path: String) -> String? {
        paths.first { path == $0 || path.hasPrefix($0 + "/") }
    }
}
