import AppKit
import AppState
import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI

/// The board.
///
/// Four things can happen under the pointer, and which one it is comes from
/// *where* the pointer is rather than from a key you are holding:
///
/// - over nothing — drag to select a group, or hold space to move the board;
/// - over a node's chrome or the band just inside its border — drag to move it;
/// - over a handle on a selected node — drag to resize it;
/// - near a node's edge — a link handle appears; drag it onto another node.
///
/// Everything else belongs to the node: a terminal keeps its clicks, its text
/// selection and its keyboard, and a web page keeps all three too. That is the
/// line the whole design is drawn along, and it is why the move band is a strip
/// around the outside rather than the whole card.
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

    /// The board's own coordinate space, which is what the viewport projects
    /// into. Named so every gesture can report where it began in those terms.
    ///
    /// A gesture's `.local` space is the view it is attached to, which for a
    /// node is the node itself — comparing that against a projected edge
    /// compares two different origins, and the answer then depends on where the
    /// node happens to be sitting. That bug stopped nodes halfway up the board.
    static let canvasSpace = "meshvy.canvas"

    /// What the current drag is doing. One value, decided when the drag starts
    /// and kept for the whole of it: letting go of ⇧ halfway through a marquee
    /// should finish the marquee, not start something else from wherever the
    /// pointer happens to be.
    private enum Drag {
        /// Where the camera was when the pan began.
        case pan(CGPoint)
        /// In world coordinates, and whether it adds to the selection.
        case marquee(from: CGPoint, to: CGPoint, additive: Bool)
        /// The node the drag started on, every node that is moving with it,
        /// where each started, and what the group is currently lined up with.
        case move(anchor: NodeID, origins: [NodeID: CGPoint], guides: CanvasGeometry.Snap)
        /// A resize in progress. The node is left alone until the drag ends —
        /// see `resizeGhost`.
        case resize(id: NodeID, handle: NodeHandle, from: CGRect, to: CGRect)
        /// A link being pulled out of an edge, and where the pointer is now.
        case link(from: NodeID, edge: NodeEdge, point: CGPoint)
        /// A node being drawn with a creation tool, in world coordinates.
        case create(tool: BoardTool, from: CGPoint, to: CGPoint)
    }

    @State private var drag: Drag?
    /// Where the pointer is, and whether it is over the board at all.
    ///
    /// Deliberately a reference rather than two `@State` values: a mouse-moved
    /// event arrives for every pixel the pointer travels, and writing `@State`
    /// on each one re-evaluates the whole board — every node, every frame, at
    /// pointer speed — for a number only the event monitors ever read. Nothing
    /// in `body` depends on it, so nothing should redraw for it. What the
    /// board *does* redraw for is `store.hover`, which only changes when the
    /// answer changes.
    private final class Cursor {
        var point: CGPoint = .zero
        var isInside = false
    }

    @State private var cursor = Cursor()
    /// Held keys the gestures need. `DragGesture` carries no modifier flags of
    /// its own, so they are tracked alongside it from an event monitor.
    @State private var shiftHeld = false
    @State private var commandHeld = false
    @State private var spaceHeld = false
    @State private var monitors: [Any] = []
    /// A drawn rectangle waiting for a repository to be named.
    @State private var pendingSpawn: CGRect?
    /// Whether the pointer is over the palette, and whether it is over the
    /// selection bar. Two flags rather than one: moving from one to the other
    /// delivers the leave after the enter, and a single flag would be left
    /// saying the pointer had gone.
    @State private var pointerOnToolbar = false
    @State private var pointerOnSelectionBar = false

    private var detail: DetailLevel { DetailLevel(scale: store.viewport.scale) }
    private var zoom: Zoom { Zoom(scale: store.viewport.scale) }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasBackdrop(
                    graph: store.graph,
                    viewport: store.viewport,
                    selection: Set(store.selected.map(\.storageKey)),
                    matching: store.matchingNodes,
                    isSearching: store.isSearching
                )
                .allowsHitTesting(false)

                // Empty-space gestures sit below the nodes, so a press that
                // lands on one belongs to it.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(boardGesture)
                    // ⇧ means "add to what is selected", so a ⇧-click that
                    // lands on nothing adds nothing rather than taking it all
                    // away.
                    .onTapGesture { if !shiftHeld { store.clearSelection() } }
                    .pointer(boardCursor, active: boardCursor != nil)

                nodeLayer

                // A creation tool owns the whole board, nodes included: while
                // one is in hand a terminal is canvas to draw on, not a
                // terminal to click into. Without this the question "did I just
                // click that agent or start drawing on it" has no good answer.
                if store.tool.isCreation {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(boardGesture)
                        // A click, not a drag. `DragGesture` has a minimum
                        // distance and so never fires for one, and a tool in
                        // hand that does nothing when you click reads as a
                        // broken tool — you get its usual size, where you
                        // clicked.
                        .onTapGesture(coordinateSpace: .named(Self.canvasSpace)) { point in
                            let origin = store.viewport.unproject(point)
                            finishCreate(
                                tool: store.tool,
                                rect: CGRect(origin: origin, size: .zero)
                            )
                        }
                        .pointer(Pointer.draw)
                }

                frameLayer
                ghostLayer
                spawnPicker
                controls
            }
            .background(Theme.canvas)
            .clipped()
            .coordinateSpace(.named(Self.canvasSpace))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    cursor.point = point
                    cursor.isInside = true
                    updateHover(at: point)
                case .ended:
                    cursor.isInside = false
                    store.hover(nil)
                }
            }
            .onAppear {
                store.viewport.size = proxy.size
                store.fitIfNeeded()
                installMonitors()
            }
            .onDisappear(perform: removeMonitors)
            .onChange(of: proxy.size) { _, newValue in
                store.viewport.size = newValue
                store.fitIfNeeded()
            }
        }
    }

    // MARK: - Nodes

    /// Every node, in one pass.
    ///
    /// Terminals, browsers and the workspace host live AppKit views and so are
    /// always mounted — dropping one would tear down a PTY or reload a page —
    /// while cards are dropped entirely once the board is zoomed out far enough
    /// that `CanvasBackdrop` draws them as plain blocks instead.
    ///
    /// They used to be two separate layers, which meant a card could never be
    /// in front of a terminal however recently you had touched it. One layer
    /// with a `zIndex` is what makes "whatever you last touched is on top" true
    /// of the whole board rather than half of it.
    private var nodeLayer: some View {
        let visible = store.viewport.visibleWorldRect()
        let nodes = store.graph.nodes.filter { node in
            node.hostsLiveContent || (detail != .block && node.frame.intersects(visible))
        }
        // Wrapped in a container of its own, because `zIndex` is resolved
        // among siblings and a `ForEach`'s children are spliced into whatever
        // holds it. Left in the board's own `ZStack`, raising a node would lift
        // it above the frame layer, the ghosts and the palette — so clicking a
        // terminal made the tools disappear behind it.
        // Indexed once, not once per node. A context menu's items are built
        // when the modifier is, so every node on the board would otherwise ask
        // the store for its links on every evaluation of this body — and each
        // of those asks copies the whole `Workspace` to read one array.
        var byNode: [NodeID: [WorkspaceLink]] = [:]
        for link in store.activeWorkspace?.links ?? [] {
            byNode[link.from, default: []].append(link)
            byNode[link.to, default: []].append(link)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(nodes) { node in
                nodeBody(node, links: byNode[node.id] ?? [])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func nodeBody(_ node: CanvasNode, links: [WorkspaceLink]) -> some View {
        let rect = store.viewport.project(node.frame)
        return body(for: node)
            .overlay { grabBand(for: node) }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .zIndex(store.stackIndex(of: node.id))
            .gesture(moveGesture(node))
            .modifier(RevealOnDoubleClick(node: node, store: store))
            .contextMenu { menu(for: node, links: links) }
    }

    @ViewBuilder
    private func body(for node: CanvasNode) -> some View {
        let dimmed = store.isSearching && !store.matches(node.id)
        let selected = store.isSelected(node.id)
        switch node.kind {
        case .workspace(let workspace):
            WorkspaceNodeView(workspace: workspace, store: store, zoom: zoom, isSelected: selected)
        case .terminal(let terminal):
            TerminalNodeView(
                node: terminal, store: store, zoom: zoom, isSelected: selected, isDimmed: dimmed
            )
        case .browser(let browser):
            BrowserNodeView(
                node: browser, store: store, zoom: zoom, isSelected: selected, isDimmed: dimmed
            )
        case .session(let summary, let status, let live):
            SessionNodeView(
                summary: summary, status: status, liveSession: live, zoom: zoom, detail: detail,
                isSelected: selected, isHovered: store.hoveredNode == node.id, isDimmed: dimmed
            )
        case .subAgent(let agent):
            SubAgentNodeView(agent: agent, zoom: zoom, isSelected: selected, isDimmed: dimmed)
        }
    }

    /// Shows an open hand over the part of a node that picks it up. The band
    /// is the one gesture on this board with nothing drawn on it, so the
    /// cursor is all there is to say it is there.
    private func grabBand(for node: CanvasNode) -> some View {
        let shape = GrabRing(band: grabBandWidth, whole: grabsAnywhere(node))
        return shape
            .fill(Color.clear)
            .contentShape(shape)
            .pointer(Pointer.move)
    }

    /// The frames, drawn above every node so a handle is never behind one.
    private var frameLayer: some View {
        // Resolved once. Asking "is this the drop target?" per node means a
        // hit test across the whole board per node, which is the one thing on
        // this layer that would scale quadratically — and it would do it on
        // every frame of a link drag.
        let target = dropTarget
        let shown = store.graph.nodes.filter { node in
            store.isSelected(node.id) || store.hoveredNode == node.id || target == node.id
                || linkSource == node.id || resizingNode == node.id
        }
        return ForEach(shown) { node in
            frame(for: node, target: target)
        }
    }

    private func frame(for node: CanvasNode, target: NodeID?) -> NodeFrame {
        let isTarget: Bool = target == node.id
        let rect: CGRect = store.viewport.project(node.frame)
        let edge: NodeEdge? = store.hoveredNode == node.id ? store.hoveredEdge : nil
        let pulling: NodeEdge? = linkSource == node.id ? linkEdge : nil
        return NodeFrame(
            rect: rect,
            zoom: zoom,
            isSelected: store.isSelected(node.id),
            isGroup: store.hasMultipleSelected,
            hoveredEdge: edge,
            linkingFrom: pulling,
            isDropTarget: isTarget,
            isAlreadyLinked: isTarget && isLinkedToSource(node.id),
            onResize: { handle, translation, ended in
                resize(node, from: handle, by: translation, ended: ended)
            },
            onLink: { linkEdge, point, ended in
                pullLink(from: node, edge: linkEdge, to: point, ended: ended)
            }
        )
    }

    // MARK: - Moving

    /// Moving a node.
    ///
    /// A node that hosts live content is taken hold of by its chrome or by the
    /// band just inside its border; a card is taken hold of anywhere. Which it
    /// is, is settled once, when the drag starts, against the node's *projected*
    /// rectangle — asking again on each change against a rectangle that is
    /// itself moving is what used to make a node give out halfway up the board.
    private func moveGesture(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                switch drag {
                case .move(let anchor, let origins, _):
                    continueMove(anchor: anchor, origins: origins, by: value.translation)
                    return
                case .pan(let origin):
                    pan(from: origin, by: value.translation)
                    return
                case .some:
                    return
                case .none:
                    break
                }
                // The board is still underneath: a node is not a hole in it.
                // Without this the hand tool and space-drag did nothing at all
                // when the drag happened to begin over a terminal, which is
                // most of a busy board.
                if store.tool == .hand || spaceHeld {
                    let origin = store.viewport.center
                    drag = .pan(origin)
                    pan(from: origin, by: value.translation)
                    return
                }
                guard store.tool == .select, canGrab(node, at: value.startLocation) else { return }
                // A drag on a node that is part of the selection moves all of
                // it; on one that is not, it moves only that node — and takes
                // the selection with it, so what you are dragging is what is
                // framed. With ⇧ the node joins the selection instead of
                // replacing it, which is what makes ⇧-dragging a group work:
                // the press through the monitor has just toggled this node
                // out of it, and this puts it back.
                if !store.isSelected(node.id) {
                    if shiftHeld { store.extendSelection(to: node.id) } else { store.select(node.id) }
                }
                var origins: [NodeID: CGPoint] = [:]
                for id in store.selected {
                    origins[id] = store.graph.node(id)?.position
                }
                if origins[node.id] == nil { origins[node.id] = node.position }
                drag = .move(anchor: node.id, origins: origins, guides: .none)
                continueMove(anchor: node.id, origins: origins, by: value.translation)
            }
            .onEnded { _ in
                switch drag {
                case .move: store.commitMove()
                case .pan: store.persistLayout()
                default: return
                }
                drag = nil
            }
    }

    /// Whether a press at this point may pick the node up.
    private func canGrab(_ node: CanvasNode, at point: CGPoint) -> Bool {
        let rect = store.viewport.project(node.frame)
        guard rect.contains(point) else { return false }
        guard !grabsAnywhere(node) else { return true }
        // The chrome is the header and whatever sits between it and the live
        // content; the band is the same seven points on every kind.
        if point.y <= rect.minY + zoom.c(node.chromeHeight) { return true }
        return CanvasGeometry.isOnBorder(point, of: rect, band: grabBandWidth)
    }

    /// Whether the whole of a node picks it up, rather than a band around it.
    ///
    /// True of a card always, and of a live node once the board is zoomed out
    /// far enough that it has stopped drawing its content — there is nothing
    /// left to protect, and a band two points wide is no use to anybody.
    private func grabsAnywhere(_ node: CanvasNode) -> Bool {
        !node.hostsLiveContent || !zoom.showsLiveContent
    }

    /// How wide the band you pick a node up by is, on screen.
    ///
    /// Exactly the inset the live view sits in, and for the same reason the
    /// inset follows the zoom: the two have to be the same strip. A wider band
    /// would reach over the terminal, where the press goes to SwiftTerm — so
    /// the open hand would promise a drag that selects text instead.
    private var grabBandWidth: CGFloat { zoom.s(CanvasGeometry.borderGrab) }

    private func continueMove(anchor: NodeID, origins: [NodeID: CGPoint], by translation: CGSize) {
        let delta = CGSize(
            width: translation.width / store.viewport.scale,
            height: translation.height / store.viewport.scale
        )
        // Everything lines up against the node the drag started on, and the
        // rest of the selection takes the same correction — so a group keeps
        // its shape and still snaps. It has to be that node and not just any
        // of them: a dictionary has no order, so picking one from it would
        // line the group up against a different member every frame.
        guard let start = origins[anchor], let node = store.graph.node(anchor) else { return }
        let proposed = CGRect(
            origin: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
            size: node.size
        )
        // ⌘ turns the guides off, which is the one thing it means on this board.
        let threshold = commandHeld ? 0 : CanvasGeometry.snapThreshold / store.viewport.scale
        let snap = CanvasGeometry.snap(
            proposed, to: store.snapTargets(excluding: Array(origins.keys)), within: threshold
        )
        store.moveNodes(origins, by: CGSize(
            width: delta.width + snap.offset.width,
            height: delta.height + snap.offset.height
        ))
        drag = .move(anchor: anchor, origins: origins, guides: snap)
    }

    // MARK: - Resizing

    /// Resizing is shown as an outline and applied when you let go.
    ///
    /// Not because it is cheaper to draw, but because of what is inside these
    /// nodes: changing a terminal's size makes SwiftTerm recompute its grid and
    /// send `SIGWINCH` to the process in it, and a full-screen program like
    /// Claude Code repaints every time. Following the pointer would do that
    /// sixty times a second for the length of the drag. One outline, one
    /// resize. Cards could take it live, but one rule for every node is worth
    /// more here than a smoother card.
    private func resize(_ node: CanvasNode, from handle: NodeHandle, by translation: CGSize, ended: Bool) {
        let world = CGSize(
            width: translation.width / store.viewport.scale,
            height: translation.height / store.viewport.scale
        )
        let target = CanvasGeometry.resize(
            node.frame, from: handle, by: world, minimum: node.minimumSize
        )
        guard ended else {
            if !store.isSelected(node.id) { store.select(node.id) }
            drag = .resize(id: node.id, handle: handle, from: node.frame, to: target)
            return
        }
        drag = nil
        store.place(node.id, frame: target)
        store.commitMove()
    }

    // MARK: - Linking

    /// The node a resize is in flight on. Its frame has to stay on screen for
    /// the whole gesture: the handle being dragged lives on it, and a handle
    /// taken out from under the pointer never reports the drag ending — which
    /// would leave `drag` set to a resize that can never finish, and with it a
    /// board that has stopped answering the pointer.
    private var resizingNode: NodeID? {
        if case .resize(let id, _, _, _)? = drag { return id }
        return nil
    }

    private var linkSource: NodeID? {
        if case .link(let from, _, _)? = drag { return from }
        return nil
    }

    private var linkEdge: NodeEdge? {
        if case .link(_, let edge, _)? = drag { return edge }
        return nil
    }

    /// The node a link being dragged would land on, if any.
    private var dropTarget: NodeID? {
        guard case .link(let from, _, let point)? = drag else { return nil }
        guard let landing = node(at: point), landing.id != from else { return nil }
        return landing.id
    }

    private func isLinkedToSource(_ id: NodeID) -> Bool {
        guard let source = linkSource else { return false }
        return store.links(touching: source).contains { $0.to == id || $0.from == id }
    }

    private func pullLink(from node: CanvasNode, edge: NodeEdge, to point: CGPoint, ended: Bool) {
        guard ended else {
            drag = .link(from: node.id, edge: edge, point: point)
            return
        }
        drag = nil
        // Letting go over nothing cancels, silently: a link means "what this
        // node is doing is context for that one", and half of that has nothing
        // to say to anybody.
        guard let target = self.node(at: point), target.id != node.id else { return }
        store.link(from: node.id, to: target.id)
    }

    // MARK: - Empty space

    /// What a drag on the board itself does, decided once when it begins.
    private var boardGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                switch drag {
                case .pan(let origin):
                    pan(from: origin, by: value.translation)
                case .marquee(let from, _, let additive):
                    drag = .marquee(from: from, to: store.viewport.unproject(value.location), additive: additive)
                case .create(let tool, let from, _):
                    drag = .create(tool: tool, from: from, to: store.viewport.unproject(value.location))
                case .move(let anchor, let origins, _):
                    continueMove(anchor: anchor, origins: origins, by: value.translation)
                default:
                    begin(value)
                }
            }
            .onEnded { value in
                defer { drag = nil }
                switch drag {
                case .marquee(let from, _, let additive):
                    finishMarquee(from: from, to: store.viewport.unproject(value.location), additive: additive)
                case .create(let tool, let from, _):
                    finishCreate(tool: tool, rect: rect(from: from, to: store.viewport.unproject(value.location)))
                case .pan:
                    store.persistLayout()
                case .move:
                    store.commitMove()
                default:
                    break
                }
            }
    }

    private func pan(from origin: CGPoint, by translation: CGSize) {
        store.viewport.center = CGPoint(
            x: origin.x - translation.width / store.viewport.scale,
            y: origin.y - translation.height / store.viewport.scale
        )
    }

    private func begin(_ value: DragGesture.Value) {
        let start = store.viewport.unproject(value.startLocation)
        if store.tool.isCreation {
            drag = .create(tool: store.tool, from: start, to: store.viewport.unproject(value.location))
            return
        }
        if store.tool == .hand || spaceHeld {
            drag = .pan(store.viewport.center)
            return
        }
        // Zoomed out past `DetailLevel.block` the cards have no views of their
        // own — `CanvasBackdrop` draws them in one pass — so a press on one
        // arrives here rather than at the card, and this layer has to work out
        // for itself that it was a node and not empty board. It cannot be a
        // live node: those keep their views at every zoom, and their own
        // gesture would have taken the press.
        if let node = node(at: value.startLocation) {
            if !store.isSelected(node.id) { store.select(node.id) }
            var origins: [NodeID: CGPoint] = [:]
            for id in store.selected { origins[id] = store.graph.node(id)?.position }
            if origins[node.id] == nil { origins[node.id] = node.position }
            drag = .move(anchor: node.id, origins: origins, guides: .none)
            continueMove(anchor: node.id, origins: origins, by: value.translation)
            return
        }
        drag = .marquee(from: start, to: store.viewport.unproject(value.location), additive: shiftHeld)
    }

    private func finishMarquee(from: CGPoint, to: CGPoint, additive: Bool) {
        let area = rect(from: from, to: to)
        // Intersection rather than containment: these nodes are hundreds of
        // points wide, and a rectangle you have to draw right around a terminal
        // is a rectangle the size of the screen.
        let caught = store.graph.nodes.filter { $0.frame.intersects(area) }.map(\.id)
        guard !caught.isEmpty else {
            if !additive { store.clearSelection() }
            return
        }
        store.select(all: additive ? store.selected + caught.filter { !store.isSelected($0) } : caught)
    }

    private func finishCreate(tool: BoardTool, rect: CGRect) {
        store.use(.select)
        // A flick of the wrist is not a request for a process. Anything smaller
        // than a deliberate rectangle gets the tool's own size instead, placed
        // where the press landed — which is also what a plain click does.
        var frame = rect
        if rect.width < BoardTool.minimumDrawn.width || rect.height < BoardTool.minimumDrawn.height {
            frame = CGRect(origin: rect.origin, size: tool.defaultSize)
        }
        switch tool {
        case .browser:
            guard let node = store.openBrowser(reveal: false) else { return }
            store.moveBrowser(node.id, to: frame.origin, size: frame.size)
            store.commitTerminalMove()
            store.select(.browser(node.id))
        case .shell:
            open(role: .shell, repo: nil, in: frame)
        case .agent:
            offerAgent(in: frame)
        case .select, .hand:
            break
        }
    }

    private func rect(from: CGPoint, to: CGPoint) -> CGRect {
        CGRect(
            x: min(from.x, to.x), y: min(from.y, to.y),
            width: abs(to.x - from.x), height: abs(to.y - from.y)
        )
    }

    // MARK: - Creating

    /// An agent has to work somewhere, and a rectangle cannot say where. One
    /// repository in the workspace answers itself; more than one asks.
    private func offerAgent(in frame: CGRect) {
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
            open(role: .repo, repo: repos[0], in: frame)
        } else {
            pendingSpawn = frame
        }
    }

    private func open(role: TerminalNode.Role, repo: WorkspaceRepo?, in frame: CGRect) {
        guard let node = store.openTerminal(role: role, repoID: repo?.id) else { return }
        store.moveTerminal(node.id, to: frame.origin, size: frame.size)
        store.commitTerminalMove()
        store.select(.terminal(node.id))
    }

    /// Where a drawn rectangle is waiting for a repository to be named.
    @ViewBuilder
    private var spawnPicker: some View {
        if let frame = pendingSpawn {
            let projected = store.viewport.project(frame)
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW AGENT IN")
                    .font(Theme.ui(9, .heavy)).tracking(0.7)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 2)
                ForEach(store.activeWorkspace?.readyRepos ?? []) { repo in
                    Button { pendingSpawn = nil; open(role: .repo, repo: repo, in: frame) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "hammer.fill")
                                .font(Theme.ui(9)).foregroundStyle(Theme.worktree)
                            Text(repo.name).font(Theme.ui(11.5)).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Corner.panel - 4, style: .continuous)
                                .fill(Theme.surface)
                        )
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
            .background(
                RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                    .fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            .position(x: projected.midX, y: projected.midY)
        }
    }

    // MARK: - What a drag looks like while it happens

    @ViewBuilder
    private var ghostLayer: some View {
        switch drag {
        case .marquee(let from, let to, _):
            let projected = store.viewport.project(rect(from: from, to: to))
            Rectangle()
                .fill(Theme.accent.opacity(0.1))
                .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
                .frame(width: projected.width, height: projected.height)
                .position(x: projected.midX, y: projected.midY)
                .allowsHitTesting(false)
        case .create(let tool, let from, let to):
            creationGhost(tool: tool, world: rect(from: from, to: to))
        case .resize(_, _, _, let to):
            resizeGhost(to)
        case .link(let from, let edge, let point):
            linkPreview(from: from, edge: edge, to: point)
        case .move(_, _, let guides):
            guideLines(guides)
        case .pan, .none:
            EmptyView()
        }
    }

    private func resizeGhost(_ world: CGRect) -> some View {
        let projected = store.viewport.project(world)
        return RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(
                RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                    .fill(Theme.accent.opacity(0.07))
            )
            .frame(width: projected.width, height: projected.height)
            .position(x: projected.midX, y: projected.midY)
            .overlay {
                Text("\(Int(world.width.rounded())) × \(Int(world.height.rounded()))")
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent))
                    .position(x: projected.maxX - 26, y: projected.maxY + 11)
            }
            .allowsHitTesting(false)
    }

    private func creationGhost(tool: BoardTool, world: CGRect) -> some View {
        let projected = store.viewport.project(world)
        let big = projected.width >= 90 && projected.height >= 54
        return RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
            )
            .overlay {
                if big {
                    VStack(spacing: 4) {
                        Image(systemName: tool.icon).font(Theme.ui(13, .semibold))
                        Text("New \(tool.label.lowercased())").font(Theme.ui(11, .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: projected.width, height: projected.height)
            .position(x: projected.midX, y: projected.midY)
            .allowsHitTesting(false)
    }

    private func linkPreview(from: NodeID, edge: NodeEdge, to point: CGPoint) -> some View {
        let rect = store.graph.node(from).map { store.viewport.project($0.frame) } ?? .zero
        let start = edge.anchor(in: rect)
        let landing = node(at: point)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: start)
                let dx = (point.x - start.x) * 0.5
                path.addCurve(
                    to: point,
                    control1: CGPoint(x: start.x + dx * 0.9, y: start.y),
                    control2: CGPoint(x: point.x - dx * 0.9, y: point.y)
                )
            }
            .stroke(
                Theme.sidechain.opacity(0.9),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4])
            )
            // A hollow end says what a release here would do, which is nothing.
            if landing == nil {
                Circle()
                    .strokeBorder(Theme.sidechain.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
    }

    /// The lines a dragged node has just lined itself up with.
    private func guideLines(_ snap: CanvasGeometry.Snap) -> some View {
        Path { path in
            for x in snap.verticals {
                let screen = store.viewport.project(CGPoint(x: x, y: 0)).x
                path.move(to: CGPoint(x: screen, y: 0))
                path.addLine(to: CGPoint(x: screen, y: store.viewport.size.height))
            }
            for y in snap.horizontals {
                let screen = store.viewport.project(CGPoint(x: 0, y: y)).y
                path.move(to: CGPoint(x: 0, y: screen))
                path.addLine(to: CGPoint(x: store.viewport.size.width, y: screen))
            }
        }
        .stroke(Theme.sidechain.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .allowsHitTesting(false)
    }

    // MARK: - Chrome on the board

    private var controls: some View {
        VStack(spacing: 8) {
            if store.hasMultipleSelected {
                SelectionBar(store: store)
                    .onHover { pointerOnSelectionBar = $0 }
                    // It appears and disappears with the selection, and a bar
                    // that vanishes from under the pointer never reports the
                    // pointer leaving — which would leave the whole board
                    // ignoring presses.
                    .onDisappear { pointerOnSelectionBar = false }
            }
            CanvasToolbar(store: store)
                .onHover { pointerOnToolbar = $0 }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// What the pointer says over empty board: a hand when a drag would move
    /// the board, a crosshair when it would draw something.
    private var boardCursor: NSCursor? {
        if store.tool.isCreation { return Pointer.draw }
        if store.tool == .hand || spaceHeld { return Pointer.move }
        return nil
    }

    // MARK: - Hit testing

    /// Whichever node is under a point, the one in front first.
    private func node(at point: CGPoint) -> CanvasNode? {
        topmost { $0.contains(point) }
    }

    /// The frontmost node whose projected rectangle passes `test`.
    ///
    /// "Frontmost" has to mean exactly what the drawing means or a click lands
    /// on the node behind the one you aimed at: raised nodes first, and among
    /// equals the one composed last, which is the one `zIndex` puts on top.
    private func topmost(_ test: (CGRect) -> Bool) -> CanvasNode? {
        var best: (node: CanvasNode, rank: Double)?
        for (index, node) in store.graph.nodes.enumerated()
        where test(store.viewport.project(node.frame)) {
            let rank = store.stackIndex(of: node.id) * 100_000 + Double(index)
            if best == nil || rank >= best!.rank { best = (node, rank) }
        }
        return best?.node
    }

    private func updateHover(at point: CGPoint) {
        // Nothing hovers but the select tool, and nothing hovers mid-drag —
        // the frame you are dragging a handle off must not move because the
        // pointer has wandered over a neighbour.
        guard store.tool == .select else { return store.hover(nil) }
        guard drag == nil else { return }
        // Within reach of an edge counts as being on the node, so the link
        // handles are already there when the pointer arrives at the edge
        // rather than appearing once it is past it. But a node whose frame
        // *contains* the point always wins over one that merely has it within
        // reach: with a 26pt gap between nodes and a link handle 20pt out, the
        // handles of a raised node otherwise reach into its neighbour and
        // swallow a press meant for that neighbour's shell prompt.
        let reach = CanvasGeometry.edgeReach
        let candidate = node(at: point)
            ?? topmost { $0.insetBy(dx: -reach, dy: -reach).contains(point) }
        guard let candidate else { return store.hover(nil) }
        let rect = store.viewport.project(candidate.frame)
        // Too small on screen to aim at an edge of, and the frame would not
        // draw the handles anyway.
        guard CanvasGeometry.HandleFit(rect).showsLinkHandles else {
            return store.hover(candidate.id)
        }
        store.hover(candidate.id, edge: CanvasGeometry.edge(at: point, of: rect))
    }

    // MARK: - Menus

    @ViewBuilder
    private func menu(for node: CanvasNode, links: [WorkspaceLink]) -> some View {
        switch node.kind {
        case .workspace(let workspace):
            if store.isOrchestratorRunning {
                Button("Restart Claude Code") { store.restartTerminal(workspace.orchestrator!.id) }
                Button("Stop Claude Code") { store.requestStopOrchestrator() }
            } else {
                Button("Start Claude Code") { store.startOrchestrator() }
            }
            Divider()
            Button("Add repositories…") { sheet = .addRepos }
            Button("Reveal folder in Finder") { store.revealInFinder(workspace.root) }
        case .terminal(let terminal):
            Button("Restart") { store.restartTerminal(terminal.id) }
            Button("Reveal folder in Finder") { store.revealInFinder(terminal.cwd) }
            Button("Copy folder path") { store.copyToClipboard(terminal.cwd) }
            Divider()
            Button("Close terminal", role: .destructive) { store.requestClose(terminal.id) }
        case .browser(let browser):
            Button("Reload") { store.reloadBrowser(browser.id) }
            Button("Open in default browser") { store.openInBrowser(browser.url) }
            Divider()
            Button("Copy URL") { store.copyToClipboard(browser.url) }
            Button("Copy node id for an agent") { store.copyToClipboard(browser.shortID) }
            Divider()
            Button("Close browser", role: .destructive) { store.closeBrowser(browser.id) }
        case .session(let summary, _, _):
            Button("Open transcript") { store.reveal(node.id) }
            Divider()
            Button("Reveal transcript file") { store.revealTranscriptFile(summary) }
            Button("Open folder in editor") { store.openInEditor(summary.resolvedPath) }
            Button("Reveal folder in Finder") { store.revealInFinder(summary.resolvedPath) }
            Divider()
            Button("Copy session ID") { store.copyToClipboard(summary.id) }
            Button("Copy path") { store.copyToClipboard(summary.resolvedPath) }
        case .subAgent(let agent):
            Button("Copy task") { store.copyToClipboard(agent.prompt) }
            if let result = agent.result {
                Button("Copy result") { store.copyToClipboard(result) }
            }
        }
        linkMenu(for: node, links: links)
    }

    /// The lines you drew yourself, and the only way to take one off again
    /// short of the inspector. Nothing else on this menu is reversible from
    /// the board, and `store.unlink` used to be reachable from nowhere at all.
    @ViewBuilder
    private func linkMenu(for node: CanvasNode, links: [WorkspaceLink]) -> some View {
        if !links.isEmpty {
            Divider()
            Menu("Links") {
                ForEach(links) { link in
                    let other = link.from == node.id ? link.to : link.from
                    Button("Remove link to \(name(of: other))") {
                        store.unlink(from: link.from, to: link.to)
                    }
                }
            }
        }
    }

    private func name(of id: NodeID) -> String {
        guard let node = store.graph.node(id) else { return "it" }
        switch node.kind {
        case .workspace(let workspace): return workspace.name
        case .terminal(let terminal): return terminal.title
        case .browser(let browser): return browser.title
        case .session(let summary, _, _): return summary.displayTitle
        case .subAgent(let agent): return agent.title
        }
    }

    // MARK: - Events
    //
    // SwiftUI surfaces neither the scroll wheel nor `magnify` outside a
    // ScrollView, reports no modifier flags on a drag, and cannot see a press
    // that an AppKit view underneath it has already taken. All four come from
    // local monitors, which see events before they are dispatched.

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify], handler: wheel),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: press),
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: key)
        ].compactMap { $0 }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        commandHeld = false
        shiftHeld = false
        spaceHeld = false
        store.persistLayout()
    }

    /// Whether the board, rather than something drawn over it or typed into,
    /// should be looking at this event at all.
    private func boardIsLive(_ event: NSEvent) -> Bool {
        // Whatever is drawn over the board owns the keyboard and the wheel
        // while it is up. The monitors are app-wide, and the cursor flag only
        // changes when the pointer moves — so a palette opened with ⌘K over a
        // pointer that then stays put would otherwise drive the board behind it.
        guard !store.isOverlayOpen else { return false }
        // A sheet is a window of its own, and takes the board out of play for
        // the same reason.
        if let window = event.window, window.isSheet || window.attachedSheet != nil { return false }
        return true
    }

    /// Whether a plain letter belongs to the board rather than to an agent.
    ///
    /// Only the letters. `isTypingIntoSomething()` is what actually keeps a
    /// keystroke out of the board while you are typing, and it is enough for
    /// everything else — but it cannot be fully relied on for a focused
    /// `WKWebView`, and a stray `b` switching tools mid-sentence is the worst
    /// version of being wrong. So the single-key tool shortcuts also stand
    /// down while anything live is selected.
    ///
    /// Deliberately **not** applied to esc, the arrows, ⌘A or ⌘⌫. ⌘A selects
    /// every node, which on any real board includes a terminal — gating all of
    /// them on the selection would mean ⌘A silently switched the keyboard off,
    /// esc included, leaving no way back to the board but the mouse.
    private func boardOwnsLetters() -> Bool { !store.hasLiveSelection }

    private func flags(_ event: NSEvent) -> NSEvent? {
        commandHeld = event.modifierFlags.contains(.command)
        shiftHeld = event.modifierFlags.contains(.shift)
        return event
    }

    /// A press anywhere on the board selects what is under it — and is passed
    /// straight on, so the terminal or the page under the pointer still gets
    /// its click. This is the one way a node hosting a live AppKit view can be
    /// selected by clicking into it: SwiftUI never sees that press.
    private func press(_ event: NSEvent) -> NSEvent? {
        // Belt and braces for the gesture that never ends: a new press means
        // whatever was in flight is over, whether SwiftUI said so or not.
        switch drag {
        case .resize, .link: drag = nil
        default: break
        }
        guard boardIsLive(event), cursor.isInside, store.tool == .select else { return event }
        // The palette and the selection bar are drawn over the board but are
        // not part of it: a press on one must not also select whatever node
        // happens to be behind it.
        guard !pointerOnToolbar, !pointerOnSelectionBar else { return event }
        guard let node = node(at: cursor.point) else {
            // A click on the board is how you leave a terminal. Nothing else
            // resigns it — SwiftUI does not take first responder away from a
            // hosted `NSView` just because something near it was clicked — so
            // without this the board's keys were off from the first click into
            // an agent until the window was closed.
            handBackKeyboard(event)
            return event
        }
        if !node.hostsLiveContent { handBackKeyboard(event) }
        // And a press in the gutter between two nodes — on a link handle, say,
        // which reaches 20pt out — belongs to whatever the hover resolved to,
        // not to whichever frame happens to contain the point.
        guard store.hoveredNode == nil || store.hoveredNode == node.id else { return event }
        if event.modifierFlags.contains(.shift) {
            store.extendSelection(to: node.id)
        } else if !store.isSelected(node.id) {
            store.select(node.id)
        } else {
            // Already selected, and possibly one of several: keep the group, and
            // just bring this one to the front.
            store.raise(node.id)
        }
        return event
    }

    /// Takes first responder off whatever had it, so the board's own keys
    /// work again. The window itself is no text input client, which is the
    /// whole test `isTypingIntoSomething` makes.
    private func handBackKeyboard(_ event: NSEvent) {
        guard let window = event.window ?? NSApp.keyWindow else { return }
        guard window.firstResponder is NSTextInputClient else { return }
        window.makeFirstResponder(nil)
    }

    private func key(_ event: NSEvent) -> NSEvent? {
        // Space is a pan modifier only while the board has the keyboard — a
        // space typed at an agent is a space — but it is tracked either way.
        // Returning early on a key-up the board does not own would leave the
        // flag down for good, and the board panning instead of selecting.
        if event.keyCode == 49 {
            let ours = boardIsLive(event) && !isTypingIntoSomething()
            spaceHeld = ours && event.type == .keyDown
            // Swallowed when it is ours: there is nothing on the board a space
            // could mean, and letting it through makes the window beep.
            return ours ? nil : event
        }
        guard boardIsLive(event) else { return event }
        // ⌘⌫ before the typing guard, and only ⌘⌫: closing the agent you are
        // looking at has to be reachable from the keyboard, and it cannot do
        // anything without asking first. Bare ⌫ is never a board key at all —
        // it belongs to whatever you are typing in.
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == .command,
           event.keyCode == 51 || event.keyCode == 117 {
            store.requestRemoveSelection()
            return nil
        }
        guard !isTypingIntoSomething() else { return event }
        // Arrows are the one key worth repeating, and the only one whose
        // repeats must not each write the layout file: the move happens on
        // every press, the save when the key comes back up.
        if event.type == .keyUp {
            if isArrow(event), !store.selected.isEmpty { store.commitMove() }
            return event
        }
        // ⌘ and nothing else. `contains(.command)` is true of ⌥⌘A too, and
        // swallowing that took Archive Workspace off the keyboard.
        let command = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock) == .command

        if command, event.charactersIgnoringModifiers == "a" {
            store.selectEverything()
            return nil
        }
        if event.modifierFlags.contains(.command) { return event }

        if isArrow(event) {
            nudge(event)
            return nil
        }
        if event.keyCode == 53 {
            store.use(.select)
            store.clearSelection()
            return nil
        }
        guard boardOwnsLetters(),
              let character = event.charactersIgnoringModifiers?.lowercased().first,
              let tool = BoardTool.allCases.first(where: { $0.key == character }) else { return event }
        store.use(tool)
        return nil
    }

    /// Whether a text field, a terminal or a page has the keyboard.
    private func isTypingIntoSomething() -> Bool {
        NSApp.keyWindow?.firstResponder is NSTextInputClient
    }

    private func isArrow(_ event: NSEvent) -> Bool {
        (123...126).contains(Int(event.keyCode))
    }

    /// Arrow keys move the selection. A world unit at a time, ten with ⇧ —
    /// the only way to place a node exactly.
    private func nudge(_ event: NSEvent) {
        guard !store.selected.isEmpty else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        default: delta = CGSize(width: 0, height: -step)
        }
        for id in store.selected {
            guard let node = store.graph.node(id) else { continue }
            store.moveNode(id, to: CGPoint(x: node.position.x + delta.width, y: node.position.y + delta.height))
        }
    }

    private func wheel(_ event: NSEvent) -> NSEvent? {
        guard boardIsLive(event), cursor.isInside else { return event }

        if event.type == .magnify {
            store.viewport.zoom(to: store.viewport.scale * (1 + event.magnification), anchor: cursor.point)
            return nil
        }
        // ⌘-scroll and pinch-less trackpad zoom both land here.
        if event.modifierFlags.contains(.command) {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
            store.viewport.zoom(to: store.viewport.scale * (1 + step), anchor: cursor.point)
            return nil
        }
        // The node you clicked into keeps the wheel, so its scrollback and its
        // page are reachable at all. Everything else pans the board.
        if let scrolling = store.scrollingNode, let node = store.graph.node(scrolling) {
            let rect = store.viewport.project(node.frame)
            if rect.contains(cursor.point), cursor.point.y > rect.minY + zoom.c(node.chromeHeight) {
                return event
            }
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

/// Double-clicking a card centres it; double-clicking a terminal belongs to the
/// terminal, which uses it to select a word.
private struct RevealOnDoubleClick: ViewModifier {
    var node: CanvasNode
    var store: MeshvyStore

    func body(content: Content) -> some View {
        if node.hostsLiveContent {
            content
        } else {
            content.onTapGesture(count: 2) { store.reveal(node.id) }
        }
    }
}
