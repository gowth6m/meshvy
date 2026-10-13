import AppKit
import SwiftUI

/// The board. Pan by dragging empty space, zoom with the scroll wheel or a
/// pinch, drag a card to pin it where you want it.
struct CanvasView: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    @State private var panOrigin: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var draggingNode: NodeID?
    @State private var hoveredNode: NodeID?
    @State private var cursorInCanvas = false
    @State private var cursorPoint = CGPoint.zero
    @State private var scrollMonitor: Any?

    /// The board's own coordinate space, which is what the viewport projects
    /// into. Named so a gesture can report where it began in those terms.
    private static let canvasSpace = "meshvy.canvas"

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
            // Named, so a drag can say where it began in the same terms the
            // viewport projects nodes into. A gesture's `.local` space is the
            // view it is attached to, which for a card is the card itself —
            // comparing that against a projected edge compares two different
            // origins, and the answer depends on where the node happens to be.
            .coordinateSpace(.named(Self.canvasSpace))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    cursorPoint = point
                    cursorInCanvas = true
                    store.hoverTerminal(scrollable(under: point))
                case .ended:
                    cursorInCanvas = false
                    store.hoverTerminal(nil)
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
        // Workspace, terminal and browser nodes host live AppKit views, so they
        // are always mounted — unmounting would tear down the PTY or reload the
        // page.
        let terminals = store.graph.nodes.filter {
            switch $0.kind {
            case .terminal, .workspace, .browser: return true
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
                        Button("Stop Claude Code") { store.requestStopOrchestrator() }
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
                    Button("Close terminal", role: .destructive) { store.requestClose(terminal.id) }
                }
            } else if case .browser(let browser) = node.kind {
                BrowserNodeView(
                    node: browser,
                    store: store,
                    zoom: zoom,
                    isSelected: store.selection == node.id,
                    isDimmed: store.isSearching && !store.matches(node.id),
                    onResize: { store.moveBrowser(browser.id, to: node.position, size: $0) }
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(terminalDrag(node))
                .onTapGesture { store.select(node.id) }
                .contextMenu {
                    Button("Reload") { store.reloadBrowser(browser.id) }
                    Button("Open in default browser") { store.openInBrowser(browser.url) }
                    Divider()
                    Button("Copy URL") { store.copyToClipboard(browser.url) }
                    Button("Copy node id for an agent") { store.copyToClipboard(browser.shortID) }
                    Divider()
                    Button("Close browser", role: .destructive) { store.closeBrowser(browser.id) }
                }
            }
        }
    }

    /// A node hosting a live AppKit view is dragged by its chrome, so the body
    /// keeps normal text selection and keyboard focus.
    ///
    /// Whether the drag has hold of the chrome is settled once, when it starts.
    /// It used to be re-asked on every change against the node's *current*
    /// projected top — which falls as the node is dragged upwards, so a node on
    /// its way up eventually failed a test it had already passed and stopped
    /// dead. That is why nothing could be moved above the workspace node: the
    /// drag gave out partway there. The same comparison mixed a local-space
    /// start with a canvas-space edge, so whether a node could be picked up at
    /// all came down to where on the board it was sitting.
    private func terminalDrag(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                if draggingNode != node.id {
                    let rect = store.viewport.project(node.frame)
                    guard value.startLocation.y <= rect.minY + zoom.s(chromeHeight(of: node)) else { return }
                    draggingNode = node.id
                    dragOrigin = node.position
                }
                guard draggingNode == node.id, let origin = dragOrigin else { return }
                store.moveNode(node.id, to: CGPoint(
                    x: origin.x + value.translation.width / store.viewport.scale,
                    y: origin.y + value.translation.height / store.viewport.scale
                ))
            }
            .onEnded { _ in
                // A drag that began in the body never moved anything, and has
                // nothing to persist.
                guard draggingNode == node.id else { return }
                draggingNode = nil
                dragOrigin = nil
                store.commitTerminalMove()
            }
    }

    /// How much of a node's top is chrome rather than live content: the header,
    /// and whatever sits between it and the body. It is the part you can take
    /// hold of to move the node, and the part the scroll wheel must not reach
    /// through — one answer, so those two can never disagree about where a
    /// card's own surface begins.
    private func chromeHeight(of node: CanvasNode) -> CGFloat {
        switch node.kind {
        case .terminal(let terminal):
            // Header and its divider, plus the status strip and its own —
            // which a plain shell does not draw.
            return terminal.sessionID == nil ? 29 : 48
        case .workspace:
            // Header plus the repository strip.
            return 78
        case .browser:
            // Header, the address bar, and the divider under each.
            return 60
        default:
            return 0
        }
    }

    // MARK: - Cards

    private var nodeLayer: some View {
        let visible = store.viewport.visibleWorldRect()
        // Everything `terminalLayer` already draws is skipped here. It used to
        // skip only terminals, so every workspace and browser node also got an
        // empty card of its own size laid over the real one — carrying a drag
        // with no chrome test, two tap gestures and a context menu that render
        // as nothing, competing with the node underneath for the same clicks.
        let nodes = store.graph.nodes.filter { node in
            switch node.kind {
            case .terminal, .workspace, .browser: return false
            default: return node.frame.intersects(visible)
            }
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
        case .terminal, .workspace, .browser:
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

    /// Which node's *body* the cursor is over, of the ones that want the scroll
    /// wheel — terminals for their scrollback, browsers for the page. The
    /// header band is excluded: that is the handle you drag the node by, and
    /// resting there should not arm what is underneath it.
    private func scrollable(under point: CGPoint) -> UUID? {
        for node in store.graph.nodes.reversed() {
            var rect = store.viewport.project(node.frame)
            let id: UUID
            switch node.kind {
            case .terminal(let terminal):
                id = terminal.id
            case .workspace(let workspace):
                guard let orchestrator = workspace.orchestrator else { continue }
                id = orchestrator.id
            case .browser(let browser):
                id = browser.id
            default:
                continue
            }
            let chrome = zoom.s(chromeHeight(of: node))
            rect.origin.y += chrome
            rect.size.height -= chrome
            if rect.height > 0, rect.contains(point) { return id }
        }
        return nil
    }

    /// Sessions that ran in a checkout, and how many are running now: the past
    /// session cards stacked under it, plus the agents on the board working in
    /// it.
    ///
    /// Counted from edges, but not every edge into a checkout is a session.
    /// The workspace's own ownership edge was counted as one, so every card
    /// claimed a session it never had — and, since that edge is live whenever
    /// the orchestrator is, turned amber across the whole row the moment one
    /// started, whatever was or was not happening in each repository.
    private func attachedSessions(to path: String) -> (total: Int, live: Int) {
        var total = 0
        var live = 0
        for edge in store.graph.edges where edge.to == .worktree(path) {
            switch edge.from {
            case .session:
                total += 1
                if edge.isLive { live += 1 }
            case .terminal(let id):
                // A plain shell is a terminal, not a session.
                guard store.activeWorkspace?.terminals.first(where: { $0.id == id })?.sessionID != nil
                else { continue }
                total += 1
                if store.terminals.isRunning(id) { live += 1 }
            default:
                continue
            }
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
            Button("Close terminal", role: .destructive) { store.requestClose(terminal.id) }
        case .workspace, .browser:
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
            Button("Open a browser here") {
                store.openBrowser(repoID: node.repoID)
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
            // Whatever is drawn over the board owns the wheel while it is up.
            // The monitor is app-wide, and `cursorInCanvas` only changes when
            // the pointer moves — so a palette opened with ⌘K, over a pointer
            // that then stays put, would otherwise pan the board behind it.
            guard !store.isOverlayOpen else { return event }
            // A sheet is a window of its own, and takes the board out of play
            // for the same reason: either the event belongs to the sheet, or
            // it belongs to the window the sheet is attached to.
            if let window = event.window, window.isSheet || window.attachedSheet != nil {
                return event
            }
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

            // A terminal the pointer has rested on keeps the wheel, so its
            // scrollback is reachable at all. Zoom still belongs to the canvas.
            if store.armedTerminal != nil { return event }

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
