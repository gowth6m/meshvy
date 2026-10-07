import CoreGraphics
import Foundation

/// Positions the board.
///
/// Sections are containers; each lane inside one is a worktree with its sessions
/// flowing to the right. Sections are sized to their content and shelf-packed, so
/// a link with one session stays small instead of reserving a full-width slot.
/// Cards the user has dragged keep their saved position, so a hand-arranged board
/// survives a refresh.
struct BoardLayout {
    var gap: CGFloat = 20
    var sectionPadding: CGFloat = 24
    /// Breathing room inside a container; its label is drawn above it.
    var sectionHeaderHeight: CGFloat = 8
    var sectionSpacing: CGFloat = 70
    /// Bounds on how many sessions sit beside a worktree before wrapping. The
    /// figure is chosen per section from its busiest lane, so a checkout with
    /// forty sessions spreads sideways instead of becoming a tall column that
    /// forces the whole board to zoom out.
    var minSessionsPerLane: Int = 3
    var maxSessionsPerLane: Int = 8
    /// Shelf width before sections wrap to a new row.
    var maxRowWidth: CGFloat = 5400

    private var sessionSize: CGSize { Theme.sessionNodeSize }
    private var worktreeSize: CGSize { Theme.worktreeNodeSize }

    struct Input {
        var sections: [BoardSection]
        var statuses: [String: SessionStatus]
        var live: [String: LiveSession]
        var pinned: [String: CGPoint]
    }

    func build(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()
        let blocks = input.sections.map { layout(section: $0, input: input) }
        place(blocks: blocks, into: &graph)
        applyPinned(&graph, pinned: input.pinned)
        return graph
    }

    // MARK: - Packing

    /// Shelf packing: fill a row left to right, wrap when the next section would
    /// overflow, and start each row below the tallest section of the previous one.
    private func place(blocks: [SectionBlock], into graph: inout CanvasGraph) {
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0

        for block in blocks {
            if origin.x > 0, origin.x + block.size.width > maxRowWidth {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + sectionSpacing)
                rowHeight = 0
            }
            graph.groups.append(CanvasGroup(
                id: block.id,
                kind: block.kind,
                title: block.title,
                subtitle: block.subtitle,
                rect: CGRect(origin: origin, size: block.size),
                seed: block.seed,
                linkID: block.linkID
            ))
            for node in block.nodes {
                var moved = node
                moved.position = CGPoint(x: node.position.x + origin.x, y: node.position.y + origin.y)
                graph.nodes.append(moved)
            }
            graph.edges.append(contentsOf: block.edges)

            rowHeight = max(rowHeight, block.size.height)
            origin.x += block.size.width + sectionSpacing
        }
    }

    /// A laid-out section with node positions relative to its own origin, so the
    /// packer can place it without redoing the interior.
    private struct SectionBlock {
        var id: String
        var kind: GroupKind
        var title: String
        var subtitle: String
        var seed: String
        var linkID: UUID?
        var size: CGSize
        var nodes: [CanvasNode]
        var edges: [CanvasEdge]
    }

    private func layout(section: BoardSection, input: Input) -> SectionBlock {
        let hasWorktreeCards = section.lanes.contains { $0.worktree != nil }
        let busiestLane = section.lanes.map(\.sessions.count).max() ?? 0
        let squarish = Int(Double(busiestLane).squareRoot().rounded(.up))
        let perRow = min(maxSessionsPerLane, max(minSessionsPerLane, squarish))

        // Width is driven by the busiest lane, so quiet sections stay compact.
        let widestLane = section.lanes.map { min($0.sessions.count, perRow) }.max() ?? 0
        var contentWidth: CGFloat = hasWorktreeCards ? worktreeSize.width : 0
        if widestLane > 0 {
            if hasWorktreeCards { contentWidth += gap }
            contentWidth += CGFloat(widestLane) * (sessionSize.width + gap) - gap
        }
        contentWidth = max(contentWidth, worktreeSize.width)

        var nodes: [CanvasNode] = []
        var edges: [CanvasEdge] = []
        var y = sectionHeaderHeight + sectionPadding
        let laneX = sectionPadding

        for lane in section.lanes {
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
                    sectionID: section.id,
                    linkID: section.linkID
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
                    sectionID: section.id,
                    linkID: section.linkID
                ))
                if let worktreeID {
                    edges.append(CanvasEdge(from: nodeID, to: worktreeID, isLive: status.isLive))
                }
                laneHeight = max(laneHeight, CGFloat(row + 1) * (sessionSize.height + gap) - gap)
            }

            y += laneHeight + gap
        }

        let size = CGSize(
            width: contentWidth + sectionPadding * 2,
            height: max(y - gap + sectionPadding, sectionHeaderHeight + sectionPadding * 2 + worktreeSize.height)
        )
        return SectionBlock(
            id: section.id, kind: section.kind, title: section.title, subtitle: section.subtitle,
            seed: section.seed, linkID: section.linkID, size: size, nodes: nodes, edges: edges
        )
    }

    private func applyPinned(_ graph: inout CanvasGraph, pinned: [String: CGPoint]) {
        guard !pinned.isEmpty else { return }
        for (offset, node) in graph.nodes.enumerated() {
            guard let position = pinned[node.id.storageKey] else { continue }
            graph.nodes[offset].position = position
            graph.nodes[offset].isPinned = true
        }
    }
}
