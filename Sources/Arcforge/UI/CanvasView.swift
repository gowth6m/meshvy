import AppKit
import SwiftUI

/// The board. Pan by dragging empty space, zoom with the scroll wheel or a
/// pinch, drag a card to pin it where you want it.
struct CanvasView: View {
    @Bindable var store: ArcforgeStore
    @Binding var sheet: ArcforgeSheet?

    @State private var panOrigin: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var draggingNode: NodeID?
    @State private var hoveredNode: NodeID?
    @State private var cursorInCanvas = false
    @State private var cursorPoint = CGPoint.zero
    @State private var scrollMonitor: Any?

    private var detail: DetailLevel { DetailLevel(scale: store.viewport.scale) }
    private var zoom: Zoom { Zoom(scale: store.viewport.scale) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasBackdrop(
                    graph: store.graph,
                    viewport: store.viewport,
                    selection: store.selection,
                    matching: store.matchingNodes,
                    isSearching: store.isSearching
                )
                .allowsHitTesting(false)

                // Empty-space interactions sit below the cards so a card's own
                // drag wins when the cursor is over one.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { store.select(nil) }

                // Terminals always render as real views: dropping them would
                // tear down the PTY, so they stay mounted at every zoom.
                terminalLayer
                if detail != .block {
                    nodeLayer
                }
            }
            .background(Theme.canvas)
            .clipped()
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    cursorPoint = point
                    cursorInCanvas = true
                case .ended:
                    cursorInCanvas = false
                }
            }
            .onAppear {
                store.viewport.size = proxy.size
                store.fitIfNeeded()
                installScrollMonitor()
            }
            .onDisappear(perform: removeScrollMonitor)
            .onChange(of: proxy.size) { _, newValue in
                store.viewport.size = newValue
                store.fitIfNeeded()
            }
        }
    }

    private var terminalLayer: some View {
        // Workspace and terminal nodes host live AppKit views, so they are
        // always mounted — unmounting would tear down the PTY.
        let terminals = store.graph.nodes.filter {
            switch $0.kind {
            case .terminal, .workspace: return true
            default: return false
            }
        }
        return ForEach(terminals) { node in
            let rect = store.viewport.project(node.frame)
            if case .workspace(let workspace) = node.kind {
                WorkspaceNodeView(
                    workspace: workspace,
                    store: store,
                    zoom: zoom,
                    isSelected: store.selection == node.id,
                    onResize: { store.resizeWorkspaceNode(to: $0) }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(terminalDrag(node))
                .onTapGesture { store.select(node.id) }
                .contextMenu {
                    if store.isOrchestratorRunning {
                        Button("Restart Claude Code") { store.restartTerminal(workspace.orchestrator!.id) }
                        Button("Stop Claude Code") { store.stopOrchestrator() }
                    } else {
                        Button("Start Claude Code") { store.startOrchestrator() }
                    }
                    Divider()
                    Button("Add repositories…") { sheet = .addRepos }
                    Button("Reveal folder in Finder") { store.revealInFinder(workspace.root) }
                }
            } else if case .terminal(let terminal) = node.kind {
                TerminalNodeView(
                    node: terminal,
                    store: store,
                    zoom: zoom,
                    isSelected: store.selection == node.id,
                    isDimmed: store.isSearching && !store.matches(node.id),
                    onResize: { store.moveTerminal(terminal.id, to: node.position, size: $0) }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(terminalDrag(node))
                .onTapGesture { store.select(node.id) }
                .contextMenu {
                    Button("Restart") { store.restartTerminal(terminal.id) }
                    Button("Reveal folder in Finder") { store.revealInFinder(terminal.cwd) }
                    Button("Copy folder path") { store.copyToClipboard(terminal.cwd) }
                    Divider()
                    Button("Close terminal", role: .destructive) { store.closeTerminal(terminal.id) }
                }
            }
        }
    }

    /// Terminals are dragged by their header so the body keeps normal text
    /// selection and keyboard focus.
    private func terminalDrag(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                guard value.startLocation.y <= store.viewport.project(node.frame).minY + zoom.s(28) else { return }
                if draggingNode != node.id {
                    draggingNode = node.id
                    dragOrigin = node.position
                }
                guard let origin = dragOrigin else { return }
                store.moveNode(node.id, to: CGPoint(
                    x: origin.x + value.translation.width / store.viewport.scale,
                    y: origin.y + value.translation.height / store.viewport.scale
                ))
            }
            .onEnded { _ in
                draggingNode = nil
                dragOrigin = nil
                store.commitTerminalMove()
            }
    }

    // MARK: - Cards

    private var nodeLayer: some View {
        let visible = store.viewport.visibleWorldRect()
        let nodes = store.graph.nodes.filter { node in
            if case .terminal = node.kind { return false }
            return node.frame.intersects(visible)
        }
        return ForEach(nodes) { node in
            let rect = store.viewport.project(node.frame)
            card(for: node)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .onHover { hovering in
                    if hovering { hoveredNode = node.id }
                    else if hoveredNode == node.id { hoveredNode = nil }
                }
                .gesture(nodeDrag(node))
                .onTapGesture(count: 2) { store.reveal(node.id) }
                .onTapGesture { store.select(node.id) }
                .contextMenu { menu(for: node) }
        }
    }

    @ViewBuilder
    private func card(for node: CanvasNode) -> some View {
        let dimmed = store.isSearching && !store.matches(node.id)
        switch node.kind {
        case .session(let summary, let status, let live):
            SessionNodeView(
                summary: summary,
                status: status,
                liveSession: live,
                zoom: zoom,
                detail: detail,
                isSelected: store.selection == node.id,
                isHovered: hoveredNode == node.id,
                isDimmed: dimmed
            )
        case .terminal, .workspace:
            EmptyView()
        case .subAgent(let agent):
            SubAgentNodeView(
                agent: agent,
                zoom: zoom,
                isSelected: store.selection == node.id,
                isDimmed: dimmed
            )
        case .worktree(let worktree):
            let attached = attachedSessions(to: worktree.path)
            WorktreeNodeView(
                worktree: worktree,
                zoom: zoom,
                detail: detail,
                isSelected: store.selection == node.id,
                isHovered: hoveredNode == node.id,
                isDimmed: dimmed,
                attachedSessions: attached.total,
                liveSessions: attached.live
            )
        }
    }

    private func attachedSessions(to path: String) -> (total: Int, live: Int) {
        var total = 0
        var live = 0
        for edge in store.graph.edges where edge.to == .worktree(path) {
            total += 1
            if edge.isLive { live += 1 }
        }
        return (total, live)
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let origin = panOrigin ?? store.viewport.center
                if panOrigin == nil { panOrigin = origin }
                store.viewport.center = CGPoint(
                    x: origin.x - value.translation.width / store.viewport.scale,
                    y: origin.y - value.translation.height / store.viewport.scale
                )
            }
            .onEnded { _ in
                panOrigin = nil
                store.persistLayout()
            }
    }

    private func nodeDrag(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if draggingNode != node.id {
                    draggingNode = node.id
                    dragOrigin = node.position
                }
                guard let origin = dragOrigin else { return }
                store.moveNode(node.id, to: CGPoint(
                    x: origin.x + value.translation.width / store.viewport.scale,
                    y: origin.y + value.translation.height / store.viewport.scale
                ))
            }
            .onEnded { _ in
                draggingNode = nil
                dragOrigin = nil
                store.commitMove()
            }
    }

    @ViewBuilder
    private func menu(for node: CanvasNode) -> some View {
        switch node.kind {
        case .session(let summary, _, _):
            Button("Open transcript") { store.reveal(node.id) }
            Divider()
            Button("Reveal transcript file") { store.revealTranscriptFile(summary) }
            Button("Open folder in editor") { store.openInEditor(summary.resolvedPath) }
            Button("Reveal folder in Finder") { store.revealInFinder(summary.resolvedPath) }
            Divider()
            Button("Copy session ID") { store.copyToClipboard(summary.id) }
            Button("Copy path") { store.copyToClipboard(summary.resolvedPath) }
        case .terminal(let terminal):
            Button("Restart") { store.restartTerminal(terminal.id) }
            Button("Close terminal", role: .destructive) { store.closeTerminal(terminal.id) }
        case .workspace:
            EmptyView()
        case .subAgent(let agent):
            Button("Copy task") { store.copyToClipboard(agent.prompt) }
            if let result = agent.result {
                Button("Copy result") { store.copyToClipboard(result) }
            }
        case .worktree(let worktree):
            Button("Open agent terminal here") {
                store.openTerminal(role: .repo, repoID: node.repoID)
            }
            Button("Open shell here") {
                store.openTerminal(role: .shell, repoID: node.repoID)
            }
            Divider()
            Button("Open in editor") { store.openInEditor(worktree.path) }
            Button("Reveal in Finder") { store.revealInFinder(worktree.path) }
            Divider()
            Button("Copy path") { store.copyToClipboard(worktree.path) }
            if let branch = worktree.branch {
                Button("Copy branch name") { store.copyToClipboard(branch) }
            }
        }
    }

    // MARK: - Scroll and pinch
    //
    // SwiftUI surfaces neither the scroll wheel nor `magnify` outside a
    // ScrollView, and events over a card would not reach a sibling event view,
    // so a local monitor is the reliable way to get both. It only acts while the
    // cursor is inside the canvas, tracked by `onContinuousHover`.

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard cursorInCanvas else { return event }

            if event.type == .magnify {
                store.viewport.zoom(to: store.viewport.scale * (1 + event.magnification), anchor: cursorPoint)
                return nil
            }

            // ⌘-scroll and pinch-less trackpad zoom both land here.
            if event.modifierFlags.contains(.command) {
                let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
                store.viewport.zoom(to: store.viewport.scale * (1 + step), anchor: cursorPoint)
                return nil
            }

            var deltaX = event.scrollingDeltaX
            var deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                deltaX *= 12
                deltaY *= 12
            }
            // AppKit has already applied the "natural scrolling" preference to
            // these deltas. `isDirectionInvertedFromDevice` only reports that it
            // did — negating on it inverts the gesture a second time.
            if store.invertScroll {
                deltaX = -deltaX
                deltaY = -deltaY
            }
            store.viewport.pan(by: CGSize(width: deltaX, height: deltaY))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        store.persistLayout()
    }
}
