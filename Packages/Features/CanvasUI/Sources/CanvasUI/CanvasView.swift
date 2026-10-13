import AppKit
import AppState
import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI

/// The board. Pan by dragging empty space, zoom with the scroll wheel or a
/// pinch, drag a card to pin it where you want it.
public struct CanvasView: View {
    @Bindable public var store: MeshvyStore
    @Binding public var sheet: MeshvySheet?

    public init(
        store: MeshvyStore,
        sheet: Binding<MeshvySheet?>
    ) {
        self.store = store
        self._sheet = sheet
    }

    @State private var panOrigin: CGPoint?
    @State private var dragOrigin: CGPoint?
    @State private var draggingNode: NodeID?
    @State private var hoveredNode: NodeID?
    @State private var cursorInCanvas = false
    @State private var cursorPoint = CGPoint.zero
    @State private var scrollMonitor: Any?
    @State private var modifierMonitor: Any?
    /// ⌘ as the board sees it. A `DragGesture` reports no modifiers, so the
    /// flag has to be tracked alongside it.
    @State private var commandHeld = false
    /// The rectangle being drawn with ⌘, in board coordinates.
    @State private var spawnRect: CGRect?
    /// A drawn rectangle waiting for a repository to be named.
    @State private var pendingSpawn: CGRect?
    /// A link being pulled out of a node: where it started, and where the
    /// pointer is now.
    @State private var linkSource: NodeID?
    @State private var linkPoint: CGPoint?

    /// The board's own coordinate space, which is what the viewport projects
    /// into. Named so a gesture can report where it began in those terms.
    private static let canvasSpace = "meshvy.canvas"

    private var detail: DetailLevel { DetailLevel(scale: store.viewport.scale) }
    private var zoom: Zoom { Zoom(scale: store.viewport.scale) }

    public var body: some View {
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
                    .gesture(boardGesture)
                    .onTapGesture { store.select(nil) }

                // Terminals always render as real views: dropping them would
                // tear down the PTY, so they stay mounted at every zoom.
                terminalLayer
                if detail != .block {
                    nodeLayer
                }
                spawnPreview
                linkPreview
                spawnPicker
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
                installModifierMonitor()
            }
            .onDisappear {
                removeScrollMonitor()
                removeModifierMonitor()
            }
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
                .overlay { linkHandle(for: node) }
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
                .overlay { linkHandle(for: node) }
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
                .overlay { linkHandle(for: node) }
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
                .overlay { linkHandle(for: node) }
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

    // MARK: - Gestures

    /// Empty space. Dragging pans the board; dragging with ⌘ held draws a new
    /// agent where you drew it.
    ///
    /// Which of the two it is, is decided when the drag starts and kept for the
    /// whole of it — letting go of ⌘ halfway through a rectangle should finish
    /// the rectangle, not start panning from wherever the pointer happens to be.
    private var boardGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                if spawnRect == nil && panOrigin == nil && commandHeld {
                    spawnRect = CGRect(origin: store.viewport.unproject(value.startLocation), size: .zero)
                }
                if spawnRect != nil {
                    let start = store.viewport.unproject(value.startLocation)
                    let now = store.viewport.unproject(value.location)
                    spawnRect = CGRect(
                        x: min(start.x, now.x), y: min(start.y, now.y),
                        width: abs(now.x - start.x), height: abs(now.y - start.y)
                    )
                    return
                }
                let origin = panOrigin ?? store.viewport.center
                if panOrigin == nil { panOrigin = origin }
                store.viewport.center = CGPoint(
                    x: origin.x - value.translation.width / store.viewport.scale,
                    y: origin.y - value.translation.height / store.viewport.scale
                )
            }
            .onEnded { _ in
                if let rect = spawnRect {
                    spawnRect = nil
                    // A flick of the wrist with ⌘ down is not a request for an
                    // agent; it takes a deliberate rectangle.
                    if rect.width >= 120, rect.height >= 90 { offerAgent(in: rect) }
                    return
                }
                panOrigin = nil
                store.persistLayout()
            }
    }

    /// The rectangle being drawn with ⌘, and what it will become.
    @ViewBuilder
    private var spawnPreview: some View {
        if let rect = spawnRect {
            let projected = store.viewport.project(rect)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08))
                )
                .overlay {
                    if projected.height > 54 {
                        VStack(spacing: 4) {
                            Image(systemName: "hammer.fill").font(Theme.ui(13, .semibold))
                            Text("New agent").font(Theme.ui(11, .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: projected.width, height: projected.height)
                .position(x: projected.midX, y: projected.midY)
                .allowsHitTesting(false)
        }
    }

    /// The line being pulled from a node's handle towards wherever it is going.
    @ViewBuilder
    private var linkPreview: some View {
        if let source = linkSource, let point = linkPoint,
           let node = store.graph.node(source) {
            let from = store.viewport.project(node.frame)
            Path { path in
                path.move(to: CGPoint(x: from.maxX, y: from.midY))
                path.addLine(to: point)
            }
            .stroke(
                Theme.sidechain.opacity(0.9),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
            )
            .allowsHitTesting(false)
        }
    }

    /// Where a drawn rectangle is waiting for a repository to be named.
    ///
    /// An agent has to work somewhere, and a rectangle cannot say where. One
    /// repository in the workspace answers itself; more than one asks.
    @ViewBuilder
    private var spawnPicker: some View {
        if let rect = pendingSpawn {
            let projected = store.viewport.project(rect)
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW AGENT IN")
                    .font(Theme.ui(9, .heavy)).tracking(0.7)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 2)
                ForEach(store.activeWorkspace?.readyRepos ?? []) { repo in
                    Button { pendingSpawn = nil; spawnAgent(repo: repo, in: rect) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hammer.fill")
                                .font(Theme.ui(9)).foregroundStyle(Theme.worktree)
                            Text(repo.name).font(Theme.ui(11.5)).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Cancel") { pendingSpawn = nil }
                    .buttonStyle(.plain)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
            .padding(10)
            .frame(width: 190)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            .position(x: projected.midX, y: projected.midY)
        }
    }

    /// One repository answers itself; more than one has to be asked about.
    private func offerAgent(in rect: CGRect) {
        let repos = store.activeWorkspace?.readyRepos ?? []
        guard !repos.isEmpty else {
            store.show(.init(
                kind: .info,
                title: "No repositories yet",
                detail: "Add one to the workspace and an agent will have somewhere to work."
            ))
            return
        }
        if repos.count == 1 {
            spawnAgent(repo: repos[0], in: rect)
        } else {
            pendingSpawn = rect
        }
    }

    private func spawnAgent(repo: WorkspaceRepo, in rect: CGRect) {
        guard let node = store.openTerminal(role: .repo, repoID: repo.id) else { return }
        store.moveTerminal(node.id, to: rect.origin, size: CGSize(width: rect.width, height: rect.height))
        store.commitTerminalMove()
        store.select(.terminal(node.id))
    }

    /// The handle a link is pulled out of: a `+` on the right edge of whichever
    /// node is selected. Drag it onto another node to link the two.
    @ViewBuilder
    private func linkHandle(for node: CanvasNode) -> some View {
        if store.selection == node.id || linkSource == node.id {
            let rect = store.viewport.project(node.frame)
            Image(systemName: "plus")
                .font(Theme.ui(9, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.sidechain))
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .position(x: rect.maxX, y: rect.midY)
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
                        .onChanged { value in
                            linkSource = node.id
                            linkPoint = value.location
                        }
                        .onEnded { value in
                            defer { linkSource = nil; linkPoint = nil }
                            guard let target = nodeID(under: value.location), target != node.id else { return }
                            store.link(from: node.id, to: target)
                        }
                )
                .help("Drag onto another node to link them")
        }
    }

    /// Whichever node is under a point, topmost first — the drop target for a
    /// link. Unlike `scrollable(under:)` the whole card counts, chrome included:
    /// you are aiming at the node, not at part of it.
    private func nodeID(under point: CGPoint) -> NodeID? {
        for node in store.graph.nodes.reversed()
        where store.viewport.project(node.frame).contains(point) {
            return node.id
        }
        return nil
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

    /// ⌘, tracked alongside the drag. A `DragGesture` carries no modifier
    /// flags of its own, and the board has to know at the moment a drag begins
    /// whether it is a pan or a new agent being drawn.
    private func installModifierMonitor() {
        guard modifierMonitor == nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            commandHeld = event.modifierFlags.contains(.command)
            return event
        }
    }

    private func removeModifierMonitor() {
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        commandHeld = false
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        store.persistLayout()
    }
}
