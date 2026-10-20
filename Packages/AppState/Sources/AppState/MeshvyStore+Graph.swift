import AppKit
import Foundation
import MeshvyCore
import MeshvyModels
import PersistenceKit

// Composing the canvas graph, hit-testing it, and the links between nodes.
extension MeshvyStore {
    // MARK: - Graph

    public func rebuild() {
        guard let workspace = activeWorkspace else {
            graph = CanvasGraph()
            return
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: allSessions.map { ($0.id, live[$0.id]?.status ?? .ended) }
        )
        graph = composer.compose(.init(
            workspace: workspace,
            sessions: allSessions,
            statuses: statuses,
            live: live,
            subAgents: subAgents,
            pinned: pinned,
            sized: sized,
            claimedSessions: terminals.claimedSessionIDs,
            showEnded: showEndedSessions,
            orchestratorRunning: isOrchestratorRunning
        ))
        recomputeMatches()
        // A node that has left the board cannot stay selected — an agent that
        // finished, a browser that was closed. Pruned rather than cleared, so
        // closing one of six selected nodes does not drop the other five.
        selected.removeAll { boardNode(for: $0) == nil }
    }

    /// The node on the board that shows `id`. A repository has no node of its
    /// own — it is a chip on the workspace node — so that is where it is drawn,
    /// for as long as it is still part of the workspace.
    public func boardNode(for id: NodeID) -> CanvasNode? {
        guard case .worktree(let path) = id else { return graph.node(id) }
        guard let workspace = activeWorkspace,
              workspace.repos.contains(where: { $0.worktreePath == path }) else { return nil }
        return graph.node(.workspace(workspace.id))
    }

    public func recomputeMatches() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { matchingNodes = []; return }
        let terms = query.split(separator: " ").map(String.init)
        matchingNodes = Set(
            graph.nodes
                .filter { node in terms.allSatisfy { node.searchText.contains($0) } }
                .map { $0.id.storageKey }
        )
    }

    public var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public func matches(_ id: NodeID) -> Bool { matchingNodes.contains(id.storageKey) }

    public func summaryLine() -> String {
        guard let workspace = activeWorkspace else { return "No workspace — create one to get started" }
        let sessions = graph.nodes.filter { if case .session = $0.kind { return true } else { return false } }.count
        let running = workspace.allTerminals.filter { terminals.isRunning($0.id) }.count
        var parts = [
            "\(workspace.readyRepos.count) \(workspace.readyRepos.count == 1 ? "repo" : "repos") on \(workspace.branch)",
            "\(sessions) \(sessions == 1 ? "session" : "sessions")"
        ]
        if running > 0 { parts.append("\(running) \(running == 1 ? "terminal" : "terminals") running") }
        let working = workspace.allTerminals.filter { activity(for: $0)?.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        let blocked = agentsNeedingYou.count
        if blocked > 0 { parts.append("\(blocked) waiting on you") }
        return parts.joined(separator: "  ·  ")
    }

    public func show(_ banner: Banner) {
        self.banner = banner
        let id = banner.id
        // Long enough to read; longer still when there is a button on it,
        // which has to be found and reached before the banner goes.
        let seconds = banner.kind == .failure ? 12 : (banner.action == nil ? 4 : 8)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    public func dismissBanner() { banner = nil }

    // MARK: - Selection

    public func select(_ id: NodeID?) {
        selected = id.map { [$0] } ?? []
        raise(id)
        focus(id)
    }

    /// Says that `id` is now the node the panels follow.
    ///
    /// Every path that changes which node is last in `selected` goes through
    /// here, because two things have to happen and neither is optional: the
    /// node stops being unread, and a session card's transcript is read off
    /// disk. ⇧-click and the marquee used to skip both, so making a session
    /// card the subject that way left the inspector saying the transcript was
    /// not loaded, with nothing that would load it.
    private func focus(_ id: NodeID?) {
        markRead(id)
        guard case .session(let sessionID)? = id else { return }
        loadTranscript(sessionID)
    }

    /// ⇧-click: adds the node to the selection, or takes it out again if it was
    /// already in. Re-selecting a node already in the set makes it the one the
    /// panels follow, which is why it is removed and appended rather than left
    /// where it was.
    public func extendSelection(to id: NodeID) {
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
            // Taking the last one out leaves the panels showing whatever is
            // still selected, which is the node before it.
            focus(selected.last)
            return
        }
        selected.append(id)
        raise(id)
        focus(id)
    }

    /// Replaces the selection wholesale — what a marquee drag ends with.
    public func select(all ids: [NodeID]) {
        selected = ids
        focus(ids.last)
    }

    public func selectEverything() { select(all: graph.nodes.map(\.id)) }

    public func clearSelection() { selected = [] }

    /// The nodes behind the selection, in selection order.
    public var selectedNodes: [CanvasNode] { selected.compactMap { graph.node($0) } }

    /// Whether anything selected hosts a terminal or a page.
    ///
    /// You select one of those by clicking into it, so while one is selected
    /// the keyboard is almost certainly meant for the agent in it — which is
    /// what the board checks before treating a keystroke as a shortcut.
    public var hasLiveSelection: Bool { selectedNodes.contains(where: \.hostsLiveContent) }

    // MARK: - The pointer

    /// Which tool is in hand. Switching away from a creation tool is the common
    /// case — you draw one agent and go back to selecting — so a tool is only
    /// sticky while it is useful.
    public func use(_ tool: BoardTool) {
        guard self.tool != tool else { return }
        self.tool = tool
        // Only the select tool hovers, so anything the last one left behind
        // has to go with it: a link handle from the previous hover would
        // otherwise stay live over the board — above the creation tool's own
        // surface, catching the drag meant for it — and a terminal would keep
        // the scroll wheel it was only holding because the pointer was on it.
        hover(nil)
        // A creation tool takes the board over completely, and a selection
        // drawn with the previous tool would keep drawing handles over a canvas
        // that no longer answers to them.
        if tool.isCreation { clearSelection() }
    }

    public func hover(_ id: NodeID?, edge: NodeEdge? = nil) {
        guard hoveredNode != id || hoveredEdge != edge else { return }
        hoveredNode = id
        hoveredEdge = edge
    }

    /// Which live node, if any, the scroll wheel belongs to.
    ///
    /// The wheel pans the board, which is right almost everywhere — but it also
    /// means a terminal can never be scrolled back through and a page can never
    /// be scrolled down. This used to be answered by a 500ms dwell timer and a
    /// floating "hold still to scroll" hint, which is a lot of machinery for a
    /// question selection already answers: the node you clicked into is the one
    /// you are working in, and it is the one that should take the wheel. Click
    /// the board and the board has it back.
    public var scrollingNode: NodeID? {
        guard let hoveredNode, isSelected(hoveredNode),
              graph.node(hoveredNode)?.hostsLiveContent == true else { return nil }
        return hoveredNode
    }

    // MARK: - Stacking
    //
    // Nodes overlap: a terminal is four times the size of a session card and a
    // board is arranged by hand. Whatever you last touched is on top, which is
    // the only stacking rule that never needs explaining. It is not persisted —
    // the board is rebuilt from the workspace on every launch, and a saved
    // z-order would be one more thing that could disagree with it.

    public func raise(_ id: NodeID?) {
        guard let id else { return }
        raisedAt += 1
        raised[id] = raisedAt
    }

    /// Where a node sits in the stack. Zero for anything never touched, so an
    /// untouched board draws in composition order exactly as it used to.
    ///
    /// A dictionary keyed by the id itself, not a list of storage keys: this
    /// is asked once per node on every evaluation of the board's body, and
    /// `storageKey` builds a `String` each time it is asked.
    public func stackIndex(of id: NodeID) -> Double {
        Double(raised[id] ?? 0)
    }

    // MARK: - Placement

    public func moveNode(_ id: NodeID, to position: CGPoint) {
        let position = Self.placeable(position)
        if case .terminal(let terminalID) = id {
            moveTerminal(terminalID, to: position)
            return
        }
        if case .browser(let browserID) = id {
            moveBrowser(browserID, to: position)
            return
        }
        pin(id, to: position)
    }

    /// Moves several nodes by one delta, touching the workspace once.
    ///
    /// Each `moveNode` on a terminal or a browser copies the whole `Workspace`
    /// value, writes it back into the array and scans the graph — fine for one
    /// node, but a group drag does it for every member of the selection on
    /// every frame of the gesture. This does the same work in a single pass.
    public func moveNodes(_ origins: [NodeID: CGPoint], by delta: CGSize) {
        guard var workspace = activeWorkspace,
              let slot = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        var moved: [NodeID: CGPoint] = [:]
        // Only written back if something in it actually moved. A `Workspace` is
        // a value holding every terminal, browser and repository, and the whole
        // app shell reads the array it lives in — so putting it back on a frame
        // where only cards moved redraws the sidebar, the top bar and the
        // status bar sixty times a second for nothing.
        var workspaceChanged = false
        for (id, origin) in origins {
            let position = Self.placeable(
                CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
            )
            moved[id] = position
            switch id {
            case .terminal(let terminalID):
                if let index = workspace.terminals.firstIndex(where: { $0.id == terminalID }) {
                    workspace.terminals[index].position = position
                    workspaceChanged = true
                }
            case .browser(let browserID):
                if let index = workspace.browsers.firstIndex(where: { $0.id == browserID }) {
                    workspace.browsers[index].position = position
                    workspaceChanged = true
                }
            default:
                pinned[id.storageKey] = position
            }
        }
        if workspaceChanged { workspaces[slot] = workspace }
        for (offset, node) in graph.nodes.enumerated() {
            guard let position = moved[node.id] else { continue }
            graph.nodes[offset].position = position
            graph.nodes[offset].isPinned = true
            // The node's own copy of the model carries the position too, and
            // the views read it from there.
            switch node.id {
            case .terminal(let id):
                if let terminal = workspace.terminals.first(where: { $0.id == id }) {
                    graph.nodes[offset].kind = .terminal(terminal)
                }
            case .browser(let id):
                if let browser = workspace.browsers.first(where: { $0.id == id }) {
                    graph.nodes[offset].kind = .browser(browser)
                }
            default: break
            }
        }
    }

    /// Moves and resizes in one call, because a handle on a node's top or left
    /// edge does both at once: the far edge stays where it is, which means the
    /// origin moves as the size changes. Two calls would show the node jump.
    public func place(_ id: NodeID, frame: CGRect) {
        let size = CGSize(width: max(1, frame.width), height: max(1, frame.height))
        let origin = Self.placeable(frame.origin)
        switch id {
        case .terminal(let terminalID):
            moveTerminal(terminalID, to: origin, size: size)
        case .browser(let browserID):
            moveBrowser(browserID, to: origin, size: size)
        case .workspace:
            resizeWorkspaceNode(to: size)
            pin(id, to: origin)
        case .session, .subAgent, .worktree:
            pin(id, to: origin)
            sized[id.storageKey] = size
            if let index = graph.nodes.firstIndex(where: { $0.id == id }) {
                graph.nodes[index].size = size
            }
        }
    }

    /// Where a node may actually be put.
    ///
    /// `BoardComposer` reads a terminal or browser at exactly `.zero` as one it
    /// has never placed, and lays it out itself. World origin is a real place —
    /// it is the workspace node's own top-left — so a node dragged or snapped
    /// to it would jump into the auto-layout column on the next rebuild. A
    /// hundredth of a unit is invisible and is not `.zero`.
    public static func placeable(_ position: CGPoint) -> CGPoint {
        position == .zero ? CGPoint(x: 0.01, y: 0.01) : position
    }

    /// Pins a node where the user put it. Pinned nodes opt out of auto-layout
    /// for good — see `BoardComposer.applyPinned`.
    private func pin(_ id: NodeID, to position: CGPoint) {
        pinned[id.storageKey] = position
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        graph.nodes[index].position = position
        graph.nodes[index].isPinned = true
    }

    /// Frames worth lining a dragged node up against: everything on the board
    /// bar the nodes being dragged, and bar anything too far off screen to be
    /// drawn, since a guide you cannot see is a pull you cannot explain.
    public func snapTargets(excluding ids: [NodeID]) -> [CGRect] {
        let visible = viewport.visibleWorldRect()
        let moving = Set(ids.map(\.storageKey))
        return graph.nodes
            .filter { !moving.contains($0.id.storageKey) && $0.frame.intersects(visible) }
            .map(\.frame)
    }

    public func commitMove() { persistLayout(); persistWorkspaces() }

    /// Puts every selected node in front of everything else, keeping their
    /// order relative to each other.
    public func bringSelectionToFront() {
        for id in selected { raise(id) }
    }

    /// Lays the selection out in a row, in the order it reads on the board now.
    ///
    /// The one tidy-up worth a button: a board of agents is dragged into place
    /// by hand, and the thing you want after an hour of that is for six nodes
    /// of different heights to share a top edge and an even gap.
    public func tidySelection() {
        let nodes = selectedNodes.sorted { $0.position.x < $1.position.x }
        guard nodes.count > 1, let origin = CGRect.bounding(nodes.map(\.frame))?.origin else { return }
        var x = origin.x
        for node in nodes {
            place(node.id, frame: CGRect(x: x, y: origin.y, width: node.size.width, height: node.size.height))
            x += node.size.width + BoardMetrics.tidyGap
        }
        commitMove()
    }

    // MARK: - Removing

    /// What ⌘⌫ does to the selection.
    ///
    /// One question for the whole of it, however many nodes are selected. The
    /// obvious shape — loop, and let each node ask for itself — cannot work:
    /// `confirmation` is a single value, so four running agents would raise
    /// four questions, three of which overwrite each other, and answering the
    /// survivor would silently close only one of the four.
    ///
    /// The cards are not closable at all. A session card *is* a transcript on
    /// disk and a sub-agent card is a line in one, so there is nothing a
    /// keystroke here could delete; the workspace node is the board itself.
    /// Saying so is better than a key that does nothing.
    public func requestRemoveSelection() {
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return }

        var terminals: [TerminalNode] = []
        var browsers: [UUID] = []
        var derived = 0
        for node in nodes {
            switch node.id {
            case .terminal(let id):
                if let terminal = activeWorkspace?.terminals.first(where: { $0.id == id }) {
                    terminals.append(terminal)
                }
            case .browser(let id): browsers.append(id)
            case .workspace, .worktree, .session, .subAgent: derived += 1
            }
        }

        guard !terminals.isEmpty || !browsers.isEmpty else {
            var detail = "Session and agent cards are read from transcripts on disk. "
                + "Hide the finished ones with ⇧⌘E."
            if nodes.count == 1, case .workspace = nodes[0].id {
                detail = "The workspace node is the board itself. Archive the workspace to put it away."
            }
            show(.init(kind: .info, title: "Nothing to close there", detail: detail))
            return
        }

        let close: () -> Void = { [weak self] in
            guard let self else { return }
            for terminal in terminals { self.closeTerminal(terminal.id) }
            for browser in browsers { self.closeBrowser(browser) }
        }

        // A browser loses nothing but a page, and an exited terminal has
        // nothing left to stop. Anything with a live process in it is worth a
        // question — including a plain shell, which is where a dev server runs.
        let live = terminals.filter { terminals_isRunning($0) }
        guard !live.isEmpty else { return close() }

        let agents = live.filter { $0.sessionID != nil }.count
        let working = live.filter { activity(for: $0)?.state == .working }.count
        let total = terminals.count + browsers.count
        var message = agents > 0
            ? "\(agents) \(agents == 1 ? "is an agent" : "are agents") and will stop. "
                + "Transcripts stay on disk."
            : "Whatever is running in \(live.count == 1 ? "it" : "them") stops."
        if working > 0 {
            message = "\(working) \(working == 1 ? "is" : "are") in the middle of a turn. " + message
        }
        confirmation = Confirmation(
            title: total == 1
                ? "Close “\(live.first?.title ?? "this")”?"
                : "Close \(total) nodes?",
            message: message,
            action: total == 1 ? "Close" : "Close all \(total)",
            run: close
        )
    }

    /// Whether a terminal still has a process in it. A one-line helper so the
    /// confirmation above reads as prose rather than as registry calls.
    private func terminals_isRunning(_ node: TerminalNode) -> Bool { terminals.isRunning(node.id) }

    // MARK: - Links
    //
    // Every other edge on the board is derived: a terminal owns the checkout it
    // runs in, the orchestrator dispatched the agent it spawned. A link is the
    // one the board cannot work out, so it is stored on the workspace — and,
    // when the far end is an agent that is running, delivered to it.

    /// Draws a link, and hands the target whatever the source is.
    public func link(from: NodeID, to: NodeID) {
        guard from != to, var workspace = activeWorkspace else { return }
        let link = WorkspaceLink(from: from, to: to)
        guard !workspace.links.contains(where: { $0.id == link.id }) else { return }
        workspace.links.append(link)
        update(workspace)
        deliverContext(for: link, in: workspace)
    }

    public func unlink(from: NodeID, to: NodeID) {
        guard var workspace = activeWorkspace else { return }
        let id = WorkspaceLink(from: from, to: to).id
        workspace.links.removeAll { $0.id == id }
        update(workspace)
    }

    /// Links either end of which is this node.
    public func links(touching id: NodeID) -> [WorkspaceLink] {
        (activeWorkspace?.links ?? []).filter { $0.from == id || $0.to == id }
    }

    /// Says what the source is to the target's own session.
    ///
    /// This is what a link is *for*: two agents that would otherwise have to be
    /// told about each other by hand now share a frame of reference. A target
    /// that is not a running agent keeps the line on the board and nothing
    /// more — it is still a note to you about how the work fits together.
    public func deliverContext(for link: WorkspaceLink, in workspace: Workspace) {
        guard let brief = contextBrief(for: link.from, in: workspace) else { return }
        // Only an agent is told. A plain shell has no one reading it — typing a
        // paragraph of prose at a bash prompt would just be a failed command —
        // and anything not running yet will be started with its own brief.
        guard let target = terminalNode(for: link.to),
              target.sessionID != nil,
              terminals.isRunning(target.id) else {
            show(.init(
                kind: .info,
                title: "Linked",
                detail: "No agent is running at the other end, so the line is on the board and nothing was sent."
            ))
            return
        }
        _ = send(brief, to: target, saying: "take context from the node you linked it to")
    }

    /// The terminal a node id stands for, if it is one at all.
    public func terminalNode(for id: NodeID) -> TerminalNode? {
        guard let workspace = activeWorkspace else { return nil }
        switch id {
        case .terminal(let uuid): return workspace.terminals.first { $0.id == uuid }
        case .workspace: return workspace.orchestrator
        default: return nil
        }
    }

    /// One paragraph describing a node, in the terms an agent can act on: where
    /// it is on disk, and what it is doing there.
    public func contextBrief(for id: NodeID, in workspace: Workspace) -> String? {
        switch id {
        case .terminal, .workspace:
            guard let node = terminalNode(for: id) else { return nil }
            var lines = ["Context: another agent in this workspace, `\(node.title)`, is working in `\(node.cwd)`."]
            if let task = node.openingTask, !task.isEmpty {
                lines.append("It was asked to: \(task)")
            } else if let message = activity(for: node)?.message, !message.isEmpty {
                lines.append("It is currently: \(message)")
            }
            lines.append("Read what it has changed there before you touch the same files, and coordinate rather than duplicating its work.")
            return lines.joined(separator: " ")
        case .worktree(let path):
            let name = workspace.repos.first { $0.worktreePath == path }?.name
                ?? URL(fileURLWithPath: path).lastPathComponent
            return "Context: the repository `\(name)` is checked out at `\(path)` on branch `\(workspace.branch)`. Treat it as in scope for this task."
        case .browser(let uuid):
            guard let browser = workspace.browsers.first(where: { $0.id == uuid }) else { return nil }
            return "Context: a browser on the board is open at \(browser.url). You can drive it with the `browser_*` tools."
        case .session(let sessionID):
            guard let summary = allSessions.first(where: { $0.id == sessionID }) else { return nil }
            return "Context: an earlier Claude Code session in `\(summary.resolvedPath)` worked on: \(summary.displayTitle). Its transcript id is \(sessionID)."
        case .subAgent(let agentID):
            guard let agent = subAgents.first(where: { $0.id == agentID }) else { return nil }
            return "Context: a sub-agent (`\(agent.kind)`) was dispatched to: \(agent.prompt)"
        }
    }

    public func resetLayout() {
        pinned.removeAll()
        sized.removeAll()
        raised.removeAll()
        raisedAt = 0
        if var workspace = activeWorkspace {
            for index in workspace.terminals.indices { workspace.terminals[index].position = .zero }
            for index in workspace.browsers.indices { workspace.browsers[index].position = .zero }
            update(workspace)
        }
        rebuild()
        fit()
        persistLayout()
    }

    public func persistLayout() {
        saved.pinned = pinned.mapValues { SavedLayout.Point(x: $0.x, y: $0.y) }
        saved.sizes = sized.mapValues { SavedLayout.Size(width: $0.width, height: $0.height) }
        saved.cameraX = viewport.center.x
        saved.cameraY = viewport.center.y
        saved.scale = viewport.scale
        saved.showEndedSessions = showEndedSessions
        saved.invertScroll = invertScroll
        saved.sidebarWidth = sidebarWidth
        saved.inspectorWidth = inspectorWidth
        saved.permissionMode = permissionMode.rawValue
        saved.notificationsEnabled = notifier.isEnabled
        saved.effort = agentEffort.rawValue
        saved.hasModelChoice = true
        saved.modelID = models.selectedModelID
        layoutStore.save(saved)
    }
}
