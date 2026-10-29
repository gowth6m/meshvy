import AppKit
import AppState
import DesignSystem
import Foundation
import MeshvyCore
import MeshvyModels
import PersistenceKit

/// Exercises the board's own handling — selection, moving, resizing, stacking,
/// linking — against the real store. `Meshvy --canvastest`.
///
/// It exists because `swift test` cannot run here: the Command Line Tools ship
/// swift-testing's framework but not a working runner, so on a machine without
/// full Xcode the suites compile and then execute nothing, silently, with exit
/// code 0 (see CONTRIBUTING). The geometry has unit tests for CI; this is the
/// same ground covered by something that actually runs locally, plus the half
/// the unit tests cannot reach — the store, the workspace model and the layout
/// file underneath them.
///
/// Run it against a throwaway home so it cannot touch a real board:
///
///     CFFIXED_USER_HOME=.build/sandbox .build/debug/Meshvy --canvastest
@MainActor
enum CanvasTest {
    private static var failures: [String] = []
    private static var checks = 0

    private static func check(_ passed: Bool, _ what: String) {
        checks += 1
        if passed {
            print("  ok   \(what)")
        } else {
            print("  FAIL \(what)")
            failures.append(what)
        }
    }

    private static func near(_ lhs: CGFloat, _ rhs: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    static func run() {
        geometry()
        chrome()

        let store = MeshvyStore.shared
        store.bootstrap()
        guard store.activeWorkspace != nil else {
            print("CANVASTEST: no workspace — make one first, e.g. --selftest <repo> --keep")
            exit(1)
        }
        // Terminals and browsers are what most of this is about, and a board
        // restored from disk starts with none: processes do not survive a quit.
        store.openTerminal(role: .shell)
        store.openTerminal(role: .shell)
        store.openBrowser(url: "about:blank", reveal: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { board(store: store) }
        }
    }

    // MARK: - Pure geometry
    //
    // The same ground as CanvasGeometryTests, run for real.

    private static func geometry() {
        print("--- geometry ---")
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let minimum = CGSize(width: 120, height: 90)

        let grown = CanvasGeometry.resize(
            rect, from: .bottomRight, by: CGSize(width: 60, height: 40), minimum: minimum
        )
        check(grown.origin == rect.origin && grown.size == CGSize(width: 460, height: 340),
              "the bottom-right handle grows a node and leaves its origin alone")

        let pulled = CanvasGeometry.resize(
            rect, from: .topLeft, by: CGSize(width: -50, height: -30), minimum: minimum
        )
        check(pulled.minX == 50 && pulled.minY == 70 && pulled.maxX == rect.maxX && pulled.maxY == rect.maxY,
              "the top-left handle moves the origin and pins the far corner")

        var minimumsHeld = true
        var farEdgesHeld = true
        for handle in NodeHandle.allCases {
            for delta in [CGSize(width: 9_999, height: 9_999), CGSize(width: -9_999, height: -9_999)] {
                let out = CanvasGeometry.resize(rect, from: handle, by: delta, minimum: minimum)
                if out.width < minimum.width || out.height < minimum.height { minimumsHeld = false }
                // A node bottoming out must not then walk across the board.
                if handle.movesLeftEdge && !near(out.maxX, rect.maxX) { farEdgesHeld = false }
                if handle.movesTopEdge && !near(out.maxY, rect.maxY) { farEdgesHeld = false }
                if handle.movesRightEdge && !near(out.minX, rect.minX) { farEdgesHeld = false }
                if handle.movesBottomEdge && !near(out.minY, rect.minY) { farEdgesHeld = false }
            }
        }
        check(minimumsHeld, "no handle can take a node below its minimum size")
        check(farEdgesHeld, "a node that bottoms out stays where it is")

        let undersized = CGRect(x: 100, y: 100, width: 80, height: 60)
        let nudged = CanvasGeometry.resize(
            undersized, from: .topLeft, by: CGSize(width: 1, height: 1), minimum: minimum
        )
        check(nudged == undersized, "a node under its minimum does not jump on the first pixel of a resize")

        let onHandle = CGPoint(
            x: rect.maxX + CanvasGeometry.frameInset + CanvasGeometry.linkOffset
                + CanvasGeometry.linkTouch / 2 - 1,
            y: rect.midY
        )
        check(CanvasGeometry.edge(at: onHandle, of: rect) == .right,
              "the hover reaches across the whole of a link handle")

        let handlesFound = NodeHandle.allCases.allSatisfy {
            CanvasGeometry.handle(at: $0.point(in: rect), of: rect) == $0
        }
        check(handlesFound, "every resize handle hit-tests where it draws")
        check(CanvasGeometry.handle(at: rect.center, of: rect) == nil,
              "the middle of a node is content, not a handle")
        check(CanvasGeometry.handle(at: CGPoint(x: rect.minX + 2, y: rect.minY + 2), of: rect) == .topLeft,
              "a corner belongs to the corner handle, not the side beside it")

        check(CanvasGeometry.isOnBorder(CGPoint(x: rect.midX, y: rect.minY + 2), of: rect)
              && !CanvasGeometry.isOnBorder(rect.center, of: rect),
              "the border band moves a node and its middle does not")

        check(CanvasGeometry.edge(at: CGPoint(x: rect.maxX + 8, y: rect.midY), of: rect) == .right
              && CanvasGeometry.edge(at: CGPoint(x: rect.maxX - 8, y: rect.midY), of: rect) == .right,
              "an edge is reachable from outside the node and from just inside it")
        check(CanvasGeometry.edge(at: rect.center, of: rect) == nil,
              "the middle of a node arms no link")
        check(CanvasGeometry.edge(at: CGPoint(x: rect.maxX, y: rect.maxY), of: rect) == nil,
              "a corner is the resize handle's, so no link starts there")
        let small = CGRect(x: 0, y: 0, width: 40, height: 40)
        check(CanvasGeometry.edge(at: small.center, of: small) == nil,
              "a node too small to have a middle still has one")
        check(CanvasGeometry.handlesAreDisjoint,
              "a resize handle and a link handle on the same edge cannot overlap")
        check(CanvasGeometry.HandleFit(CGRect(x: 0, y: 0, width: 94, height: 46)) == .cornersOnly,
              "a card shrunk on screen keeps its corners and drops its sides")

        let snap = CanvasGeometry.snap(rect, to: [CGRect(x: 600, y: 104, width: 200, height: 200)], within: 7)
        check(near(snap.offset.height, 4) && snap.offset.width == 0 && snap.horizontals == [104],
              "a frame within reach is pulled into line, and says which line")
        check(CanvasGeometry.snap(rect, to: [CGRect(x: 2_000, y: 2_000, width: 10, height: 10)], within: 7).isEmpty,
              "nothing within reach means nothing moves")
    }

    /// The one thing about the chrome that is not a matter of taste: whatever
    /// height a band takes, the live view below it must keep the same *world*
    /// size at every zoom it is drawn at. `FlippedContainer` lays the hosted
    /// view out at `frame.size / scale`, so a band that grows faster than the
    /// zoom shrinks the terminal in world units — and SwiftTerm recomputes its
    /// grid and `SIGWINCH`es the agent on every step of a pinch.
    private static func chrome() {
        print("--- a terminal's world size does not move with the zoom ---")
        let band = CanvasGeometry.borderGrab
        let header = BoardMetrics.Chrome.header
        var stable = true
        for scale in [0.55, 0.62, 0.8, 1.0, 1.4, 2.0, 3.0] {
            let zoom = Zoom(scale: CGFloat(scale))
            let worldChrome = zoom.c(header) / CGFloat(scale)
            let worldBand = zoom.s(band) / CGFloat(scale)
            if !near(worldChrome, header, 0.001) || !near(worldBand, band, 0.001) { stable = false }
        }
        check(stable, "every band holds its world size at each zoom a node draws its content at")

        // Below that, nothing live is drawn and the band is free to grow for
        // the words in it — which is what stops a header printing over itself.
        let far = Zoom(scale: 0.3)
        check(!far.showsLiveContent && far.c(header) > far.s(header),
              "and grows for its type once the node is only showing what it is")
    }

    // MARK: - The board

    private static func board(store: MeshvyStore) {
        print("--- selection ---")
        let ids = store.graph.nodes.map(\.id)
        guard ids.count >= 3 else {
            print("CANVASTEST: only \(ids.count) nodes on the board, need at least 3")
            exit(1)
        }

        store.select(ids[0])
        check(store.selected == [ids[0]] && store.selection == ids[0],
              "selecting one node selects exactly it")

        store.extendSelection(to: ids[1])
        check(store.selected.count == 2 && store.selection == ids[1],
              "⇧-click adds to the selection and the panels follow the newest")
        store.extendSelection(to: ids[1])
        check(store.selected == [ids[0]], "⇧-clicking a selected node takes it out again")

        store.select(all: Array(ids.prefix(3)))
        check(store.selected.count == 3 && store.hasMultipleSelected, "a marquee replaces the selection")
        store.selection = ids[0]
        check(store.selected == [ids[0]],
              "writing `selection` from outside the canvas replaces the whole selection")
        store.clearSelection()
        check(store.selected.isEmpty && store.selection == nil, "the selection can be emptied")

        print("--- stacking ---")
        store.raise(ids[0])
        store.raise(ids[1])
        check(store.stackIndex(of: ids[1]) > store.stackIndex(of: ids[0]),
              "the last node raised is on top")
        store.raise(ids[0])
        check(store.stackIndex(of: ids[0]) > store.stackIndex(of: ids[1]),
              "raising again moves a node back to the front rather than stacking twice")

        print("--- moving and resizing ---")
        for id in ids {
            guard let before = store.graph.node(id) else { continue }
            let kind = label(for: id)

            let target = CGPoint(x: before.position.x + 137, y: before.position.y - 89)
            store.moveNode(id, to: target)
            let moved = store.graph.node(id)
            check(moved.map { near($0.position.x, target.x) && near($0.position.y, target.y) } ?? false,
                  "a \(kind) node moves where it is put")

            let bigger = CGRect(
                origin: target,
                size: CGSize(width: before.size.width + 120, height: before.size.height + 70)
            )
            store.place(id, frame: bigger)
            let grown = store.graph.node(id)
            check(grown.map { near($0.size.width, bigger.width) && near($0.size.height, bigger.height) } ?? false,
                  "a \(kind) node resizes")

            // What a drag on a top-left handle produces: smaller, and moved.
            let fromCorner = CanvasGeometry.resize(
                bigger, from: .topLeft, by: CGSize(width: 40, height: 30), minimum: before.minimumSize
            )
            store.place(id, frame: fromCorner)
            let pulled = store.graph.node(id)
            check(pulled.map { near($0.position.x, fromCorner.minX) && near($0.size.width, fromCorner.width) } ?? false,
                  "a \(kind) node moves and resizes together, as a corner handle makes it")
        }

        print("--- the workspace node keeps a height per state ---")
        guard let workspaceID = store.activeWorkspace?.id else { exit(1) }
        let runningBefore = store.activeWorkspace?.boardHeight ?? 0
        store.place(.workspace(workspaceID), frame: CGRect(x: 0, y: 0, width: 900, height: 333))
        check(!store.isCoordinatorRunning
              && near(store.activeWorkspace?.idleBoardHeight ?? 0, 333)
              && near(store.activeWorkspace?.boardHeight ?? 0, runningBefore),
              "resizing the collapsed workspace node sets its idle height and leaves the running one alone")

        print("--- tools and the pointer ---")
        store.use(.agent)
        check(store.tool == .agent && store.selected.isEmpty,
              "picking a creation tool drops the selection it would draw over")
        store.use(.select)
        check(store.tool == .select, "and the select tool comes back")

        let live = store.graph.nodes.first { $0.hostsLiveContent }
        if let live {
            store.clearSelection()
            store.hover(live.id, edge: .right)
            check(store.hoveredNode == live.id && store.hoveredEdge == .right,
                  "hovering an edge is recorded, so the link handles have something to draw from")
            check(store.scrollingNode == nil,
                  "the wheel stays with the board over a node that is only hovered")
            store.select(live.id)
            check(store.scrollingNode == live.id,
                  "the node you clicked into takes the wheel")
            store.clearSelection()
            check(store.scrollingNode == nil, "and hands it back when nothing is selected")
            store.hover(nil)
        }

        print("--- lining up ---")
        let movable = Array(store.graph.nodes.prefix(3)).map(\.id)
        store.select(all: movable)
        store.tidySelection()
        let tidied = movable.compactMap { store.graph.node($0) }.sorted { $0.position.x < $1.position.x }
        let sameTop = tidied.allSatisfy { near($0.position.y, tidied[0].position.y) }
        var evenGaps = true
        for (left, right) in zip(tidied, tidied.dropFirst()) {
            if !near(right.position.x - (left.position.x + left.size.width), BoardMetrics.tidyGap) {
                evenGaps = false
            }
        }
        check(sameTop, "lining a selection up gives every node the same top edge")
        check(evenGaps, "and the same gap between each")
        store.clearSelection()

        print("--- framing ---")
        guard let far = store.graph.nodes.last else { exit(1) }
        store.viewport.size = CGSize(width: 1_200, height: 800)
        store.select(far.id)
        store.zoomToSelection()
        check(near(store.viewport.center.x, far.frame.center.x, 1)
              && near(store.viewport.center.y, far.frame.center.y, 1),
              "⌘2 puts the selection in the middle of the screen")
        store.clearSelection()

        print("--- links ---")
        let linkFrom = ids[1]
        let linkTo = ids[2]
        store.link(from: linkFrom, to: linkTo)
        check(store.links(touching: linkFrom).count == 1, "a link is drawn between two nodes")
        store.link(from: linkFrom, to: linkTo)
        check(store.links(touching: linkFrom).count == 1, "the same link cannot be drawn twice")
        store.link(from: linkFrom, to: linkFrom)
        check(store.links(touching: linkFrom).count == 1, "a node cannot be linked to itself")
        store.unlink(from: linkFrom, to: linkTo)
        check(store.links(touching: linkFrom).isEmpty, "a link can be taken off again")

        print("--- snap targets ---")
        let targets = store.snapTargets(excluding: [ids[0]])
        check(!targets.contains { $0 == store.graph.node(ids[0])?.frame },
              "the node being dragged is not something to line it up against")

        print("--- the world origin is a real place ---")
        if let node = store.graph.nodes.first(where: { $0.hostsLiveContent && !isWorkspace($0.id) }) {
            store.moveNode(node.id, to: .zero)
            let landed = store.graph.node(node.id)?.position ?? .zero
            check(landed != .zero,
                  "a node dropped on the world origin is nudged off it, so the composer does not re-place it")
        }

        print("--- closing ---")
        let closable = store.graph.nodes.filter { $0.hostsLiveContent && !isWorkspace($0.id) }
        if closable.count >= 2 {
            store.confirmation = nil
            store.select(all: closable.map { $0.id })
            store.requestRemoveSelection()
            // One question for the whole selection. Looping and letting each
            // node ask for itself cannot work: `confirmation` is a single
            // value, so all but the last would be silently dropped.
            check(store.confirmation != nil, "closing a selection asks first")
            let before = store.graph.nodes.count
            store.confirmation?.run()
            store.confirmation = nil
            check(store.graph.nodes.count <= before - closable.count,
                  "and answering it closes every node that was selected, not just one")
        }

        print("--- what survives a save ---")
        store.commitMove()
        let sizes = store.saved.sizes ?? [:]
        let cards = store.graph.nodes.filter { !$0.hostsLiveContent }
        check(cards.isEmpty || cards.allSatisfy { sizes[$0.id.storageKey] != nil },
              "a resized card is written to the layout file")
        // The one that matters most: an older layout must still open.
        let legacy = Data("""
        {"version":1,"pinned":{"t:x":{"x":1,"y":2}},"cameraX":3,"cameraY":4,"scale":0.5,\
        "grouping":"link","showEndedSessions":true,"invertScroll":false,"sidebarWidth":262,\
        "inspectorWidth":430,"permissionMode":"acceptEdits","notificationsEnabled":false}
        """.utf8)
        let decoded = try? JSONDecoder().decode(SavedLayout.self, from: legacy)
        check(decoded?.pinned["t:x"] != nil && decoded?.sizes == nil,
              "a layout saved before node sizes existed still decodes")

        let workspaceJSON = Data("""
        {"id":"\(UUID().uuidString)","name":"Old","branch":"main","root":"/tmp/old",\
        "repos":[],"terminals":[],"browsers":[],"boardWidth":780,"boardHeight":520,\
        "createdAt":0}
        """.utf8)
        let oldWorkspace = try? JSONDecoder().decode(Workspace.self, from: workspaceJSON)
        check(oldWorkspace?.idleBoardHeight == Workspace.idleHeight,
              "a workspace saved before the idle height existed reads the default")

        print("")
        print("\(checks - failures.count)/\(checks) checks passed")
        for failure in failures { print("  FAILED: \(failure)") }
        print(failures.isEmpty ? "CANVASTEST OK" : "CANVASTEST FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }

    private static func isWorkspace(_ id: NodeID) -> Bool {
        if case .workspace = id { return true }
        return false
    }

    private static func label(for id: NodeID) -> String {
        switch id {
        case .session: return "session"
        case .worktree: return "repository"
        case .terminal: return "terminal"
        case .workspace: return "workspace"
        case .subAgent: return "sub-agent"
        case .browser: return "browser"
        }
    }
}
