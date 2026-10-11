import CoreGraphics
import Foundation

/// Lays out one workspace as a tree.
///
/// The workspace itself is the parent node — it hosts the orchestrator's Claude
/// Code session and names the repositories that belong to it. Its repositories
/// sit in a row beneath it, and every sub-agent the orchestrator dispatches
/// appears as its own node to the side, linked back to the parent.
struct BoardComposer {
    struct Input {
        var workspace: Workspace
        /// Live git state keyed by worktree path.
        var worktrees: [String: Worktree]
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

        // 1. The parent.
        let parentSize = CGSize(
            width: workspace.boardWidth,
            height: input.orchestratorRunning ? workspace.boardHeight : Workspace.idleHeight
        )
        graph.nodes.append(CanvasNode(
            id: .workspace(workspace.id),
            kind: .workspace(workspace),
            position: .zero,
            size: parentSize
        ))

        // 2. Repositories in a row beneath it, each linked to the parent.
        let repoRowY = parentSize.height + rowGap
        let repoWidth = Theme.worktreeNodeSize.width
        let totalRepoWidth = CGFloat(workspace.repos.count) * (repoWidth + gap) - gap
        var repoX = max(0, (parentSize.width - totalRepoWidth) / 2)

        let index = PathIndex(paths: workspace.repos.map(\.worktreePath))
        var byRepo: [String: [SessionSummary]] = [:]
        for session in input.sessions {
            guard !input.claimedSessions.contains(session.id) else { continue }
            let status = input.statuses[session.id] ?? .ended
            guard input.showEnded || status.isLive else { continue }
            guard let path = index.owner(of: session.resolvedPath) else { continue }
            byRepo[path, default: []].append(session)
        }

        for repo in workspace.repos {
            let worktree = input.worktrees[repo.worktreePath] ?? placeholder(for: repo, workspace: workspace)
            let nodeID = NodeID.worktree(repo.worktreePath)
            graph.nodes.append(CanvasNode(
                id: nodeID,
                kind: .worktree(worktree),
                position: CGPoint(x: repoX, y: repoRowY),
                size: Theme.worktreeNodeSize,
                repoID: repo.id
            ))
            graph.edges.append(CanvasEdge(
                from: .workspace(workspace.id), to: nodeID,
                isLive: input.orchestratorRunning, kind: .owns
            ))

            // Past sessions for this repo stack under its card.
            let sessions = (byRepo[repo.worktreePath] ?? []).sorted { $0.lastActivityAt > $1.lastActivityAt }
            var y = repoRowY + Theme.worktreeNodeSize.height + gap
            for session in sessions.prefix(6) {
                let status = input.statuses[session.id] ?? .ended
                graph.nodes.append(CanvasNode(
                    id: .session(session.id),
                    kind: .session(session, status: status, live: input.live[session.id]),
                    position: CGPoint(x: repoX, y: y),
                    size: Theme.sessionNodeSize,
                    repoID: repo.id
                ))
                graph.edges.append(CanvasEdge(from: .session(session.id), to: nodeID, isLive: status.isLive))
                y += Theme.sessionNodeSize.height + gap
            }
            repoX += repoWidth + gap
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
                from: .workspace(workspace.id), to: .subAgent(agent.id),
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
            if let repoID = terminal.repoID,
               let repo = workspace.repos.first(where: { $0.id == repoID }) {
                graph.edges.append(CanvasEdge(
                    from: .terminal(terminal.id), to: .worktree(repo.worktreePath),
                    isLive: true, kind: .owns
                ))
            }
        }

        applyPinned(&graph, pinned: input.pinned)
        return graph
    }

    private func placeholder(for repo: WorkspaceRepo, workspace: Workspace) -> Worktree {
        Worktree(
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
