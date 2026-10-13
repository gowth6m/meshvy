import CoreGraphics
import Foundation

/// Lays out one workspace as a tree.
///
/// The workspace itself is the parent node — it hosts the orchestrator's Claude
/// Code session and names the repositories that belong to it. A repository is a
/// chip on the parent, not a node of its own: the board is for what runs in
/// them. Past sessions sit in a row beneath the parent, a column for each
/// repository they ran in, and every agent the orchestrator dispatches appears
/// as its own node to the side, linked back to the parent.
struct BoardComposer {
    struct Input {
        var workspace: Workspace
        var sessions: [SessionSummary]
        var statuses: [String: SessionStatus]
        var live: [String: LiveSession]
        var subAgents: [SubAgent]
        var pinned: [String: CGPoint]
        /// Sessions already shown by a terminal node, so no duplicate card.
        var claimedSessions: Set<String>
        var showEnded: Bool
        var orchestratorRunning: Bool
    }

    private let gap: CGFloat = 26
    private let rowGap: CGFloat = 70
    private let subAgentSize = CGSize(width: 256, height: 108)

    func compose(_ input: Input) -> CanvasGraph {
        var graph = CanvasGraph()
        let workspace = input.workspace
        let parent = NodeID.workspace(workspace.id)

        // 1. The parent.
        let parentSize = CGSize(
            width: workspace.boardWidth,
            height: input.orchestratorRunning ? workspace.boardHeight : Workspace.idleHeight
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
        let columnWidth = Theme.sessionNodeSize.width
        let rowY = parentSize.height + rowGap
        let totalWidth = CGFloat(columns.count) * (columnWidth + gap) - gap
        var columnX = max(0, (parentSize.width - totalWidth) / 2)

        for repo in columns {
            let sessions = (byRepo[repo.worktreePath] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            var y = rowY
            for session in sessions.prefix(6) {
                let status = input.statuses[session.id] ?? .ended
                graph.nodes.append(CanvasNode(
                    id: .session(session.id),
                    kind: .session(session, status: status, live: input.live[session.id]),
                    position: CGPoint(x: columnX, y: y),
                    size: Theme.sessionNodeSize,
                    repoID: repo.id
                ))
                graph.edges.append(CanvasEdge(from: .session(session.id), to: parent, isLive: status.isLive))
                y += Theme.sessionNodeSize.height + gap
            }
            columnX += columnWidth + gap
        }

        // 3. Sub-agents the orchestrator dispatched, to the right of the parent.
        var agentY: CGFloat = 0
        let agentX = parentSize.width + rowGap
        for agent in input.subAgents {
            graph.nodes.append(CanvasNode(
                id: .subAgent(agent.id),
                kind: .subAgent(agent),
                position: CGPoint(x: agentX, y: agentY),
                size: subAgentSize
            ))
            graph.edges.append(CanvasEdge(
                from: parent, to: .subAgent(agent.id),
                isLive: agent.state.isRunning, kind: .dispatched
            ))
            agentY += subAgentSize.height + gap
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
            // An agent the orchestrator spawned is its child; draw that so the
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
        return graph
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
