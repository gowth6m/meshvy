import CoreGraphics
import Foundation
import MeshvyCore
import MeshvyModels

/// Lays out one workspace as a tree.
///
/// The workspace itself is the parent node — it hosts the coordinator's Claude
/// Code session and names the repositories that belong to it. A repository is a
/// chip on the parent, not a node of its own: the board is for what runs in
/// them. Past sessions sit in a row beneath the parent, a column for each
/// repository they ran in, and every agent the coordinator dispatches appears
/// as its own node to the side, linked back to the parent.
public struct BoardComposer {
    public init() {}

    public struct Input {
        public var workspace: Workspace
        public var sessions: [SessionSummary]
        public var statuses: [String: SessionStatus]
        public var live: [String: LiveSession]
        public var subAgents: [SubAgent]
        public var pinned: [String: CGPoint]
        /// Sizes for the cards the user has resized.
        public var sized: [String: CGSize]
        /// Sessions already shown by a terminal node, so no duplicate card.
        public var claimedSessions: Set<String>
        public var showEnded: Bool
        public var coordinatorRunning: Bool

        public init(
            workspace: Workspace,
            sessions: [SessionSummary],
            statuses: [String: SessionStatus],
            live: [String: LiveSession],
            subAgents: [SubAgent],
            pinned: [String: CGPoint],
            sized: [String: CGSize] = [:],
            claimedSessions: Set<String>,
            showEnded: Bool,
            coordinatorRunning: Bool
        ) {
            self.workspace = workspace
            self.sessions = sessions
            self.statuses = statuses
            self.live = live
            self.subAgents = subAgents
            self.pinned = pinned
            self.sized = sized
            self.claimedSessions = claimedSessions
            self.showEnded = showEnded
            self.coordinatorRunning = coordinatorRunning
        }
    }

    private let gap: CGFloat = 26
    private let rowGap: CGFloat = 70
    private let subAgentSize = BoardMetrics.subAgentNode

    public func compose(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()
        let workspace = input.workspace
        let parent = NodeID.workspace(workspace.id)

        // 1. The parent.
        let parentSize = CGSize(
            width: workspace.boardWidth,
            height: input.coordinatorRunning ? workspace.boardHeight : workspace.idleBoardHeight
        )
        graph.nodes.append(CanvasNode(
            id: parent,
            kind: .workspace(workspace),
            position: .zero,
            size: parentSize
        ))

        // 2. Past sessions in a row beneath it: a column for each repository
        // that has any, in the order the parent's chips list them, each card
        // linked to the parent. A repository with nothing to show leaves no
        // gap — there is no card of its own holding its place.
        let index = PathIndex(paths: workspace.repos.map(\.worktreePath))
        var byRepo: [String: [SessionSummary]] = [:]
        for session in input.sessions {
            guard !input.claimedSessions.contains(session.id) else { continue }
            let status = input.statuses[session.id] ?? .ended
            guard input.showEnded || status.isLive else { continue }
            guard let path = index.owner(of: session.resolvedPath) else { continue }
            byRepo[path, default: []].append(session)
        }

        let columns = workspace.repos.filter { byRepo[$0.worktreePath] != nil }
        let columnWidth = BoardMetrics.sessionNode.width
        let rowY = parentSize.height + rowGap
        let totalWidth = CGFloat(columns.count) * (columnWidth + gap) - gap
        var columnX = max(0, (parentSize.width - totalWidth) / 2)

        for repo in columns {
            let sessions = (byRepo[repo.worktreePath] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            var y = rowY
            for session in sessions.prefix(6) {
                let status = input.statuses[session.id] ?? .ended
                let id = NodeID.session(session.id)
                // A card the user has resized keeps its size, and the column
                // stacks around it — laying out by the default height and
                // resizing afterwards would print a tall card over the next one.
                let size = input.sized[id.storageKey] ?? BoardMetrics.sessionNode
                graph.nodes.append(CanvasNode(
                    id: id,
                    kind: .session(session, status: status, live: input.live[session.id]),
                    position: CGPoint(x: columnX, y: y),
                    size: size,
                    repoID: repo.id
                ))
                graph.edges.append(CanvasEdge(from: id, to: parent, isLive: status.isLive))
                y += size.height + gap
            }
            columnX += columnWidth + gap
        }

        // 3. Sub-agents the coordinator dispatched, to the right of the parent.
        var agentY: CGFloat = 0
        let agentX = parentSize.width + rowGap
        for agent in input.subAgents {
            let id = NodeID.subAgent(agent.id)
            let size = input.sized[id.storageKey] ?? subAgentSize
            graph.nodes.append(CanvasNode(
                id: id,
                kind: .subAgent(agent),
                position: CGPoint(x: agentX, y: agentY),
                size: size
            ))
            graph.edges.append(CanvasEdge(
                from: parent, to: id,
                isLive: agent.state.isRunning, kind: .dispatched
            ))
            agentY += size.height + gap
        }

        // 4. Free-floating terminals the user opened per repo.
        var terminalOrigin = CGPoint(x: agentX, y: max(agentY + rowGap, parentSize.height + rowGap))
        for terminal in workspace.terminals {
            var position = terminal.position
            if position == .zero {
                position = terminalOrigin
                terminalOrigin.y += terminal.size.height + gap
            }
            graph.nodes.append(CanvasNode(
                id: .terminal(terminal.id),
                kind: .terminal(terminal),
                position: position,
                size: terminal.size,
                repoID: terminal.repoID
            ))
            // An agent the coordinator spawned is its child; draw that so the
            // delegation tree is visible. One you opened in a repository yourself
            // still belongs to the workspace, and the repository is a chip on
            // the parent rather than a node, so its edge runs to the parent too.
            if terminal.bridgeID != nil {
                graph.edges.append(CanvasEdge(
                    from: parent, to: .terminal(terminal.id),
                    isLive: true, kind: .dispatched
                ))
            } else if let repoID = terminal.repoID,
                      workspace.repos.contains(where: { $0.id == repoID }) {
                graph.edges.append(CanvasEdge(
                    from: .terminal(terminal.id), to: parent,
                    isLive: true, kind: .owns
                ))
            }
        }

        // 5. Browsers, to the left of the parent: the running application the
        // repositories add up to, facing the agents building it.
        var browserY: CGFloat = 0
        for browser in workspace.browsers {
            var position = browser.position
            if position == .zero {
                position = CGPoint(x: -(browser.size.width + rowGap), y: browserY)
                browserY += browser.size.height + gap
            }
            graph.nodes.append(CanvasNode(
                id: .browser(browser.id),
                kind: .browser(browser),
                position: position,
                size: browser.size,
                repoID: browser.repoID
            ))
            graph.edges.append(CanvasEdge(
                from: .browser(browser.id), to: parent,
                isLive: true, kind: .watches
            ))
        }

        // 6. Links drawn by hand. Added last, so an end that has since left the
        //    board — a terminal closed, an agent finished — simply drops the
        //    line rather than leaving it hanging in space.
        let present = Set(graph.nodes.map(\.id))
        for link in workspace.links where present.contains(link.from) && present.contains(link.to) {
            graph.edges.append(CanvasEdge(from: link.from, to: link.to, isLive: true, kind: .feeds))
        }

        applyPinned(&graph, pinned: input.pinned)
        applySized(&graph, sized: input.sized)
        return graph
    }

    /// Holds the floor on every card.
    ///
    /// The sizes themselves are applied as each card is placed, so a column
    /// stacks around them; this is only the clamp, which the stacking cannot
    /// do for itself because a node's minimum is a property of the node and
    /// not of the dictionary it came from.
    private func applySized(_ graph: inout CanvasGraph, sized: [String: CGSize]) {
        guard !sized.isEmpty else { return }
        for (offset, node) in graph.nodes.enumerated() where !node.hostsLiveContent {
            graph.nodes[offset].size = CGSize(
                width: max(node.minimumSize.width, node.size.width),
                height: max(node.minimumSize.height, node.size.height)
            )
        }
    }

    private func applyPinned(_ graph: inout CanvasGraph, pinned: [String: CGPoint]) {
        guard !pinned.isEmpty else { return }
        for (offset, node) in graph.nodes.enumerated() {
            // Terminals and browsers carry their own saved position on the model.
            if case .terminal = node.kind { continue }
            if case .browser = node.kind { continue }
            guard let position = pinned[node.id.storageKey] else { continue }
            graph.nodes[offset].position = position
            graph.nodes[offset].isPinned = true
        }
    }
}

/// Longest-prefix path ownership, with symlinks resolved.
///
/// The CLI records `cwd` after resolving symlinks (`/tmp` comes back as
/// `/private/tmp`), so comparing raw strings silently fails to attach sessions.
public struct PathIndex {
    private let canonical: [(canonical: String, original: String)]

    public init(paths: [String]) {
        canonical = paths
            .map { (PathIndex.canonicalize($0), $0) }
            .sorted { $0.0.count > $1.0.count }
    }

    public func owner(of path: String) -> String? {
        let target = PathIndex.canonicalize(path)
        return canonical.first { target == $0.canonical || target.hasPrefix($0.canonical + "/") }?.original
    }

    public static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
