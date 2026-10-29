import AppKit
import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI

/// Everything drawn *around* a node rather than in it: the selection frame, the
/// eight handles that resize it, and the four handles a link is pulled out of.
///
/// One view for all five kinds of node. The old board drew a bespoke corner
/// grip inside each of the three live node views — each with its own minimum
/// size, its own glyph and, in the workspace's case, an `opacity(isRunning)`
/// that hid it exactly when the node was at its smallest. A card could not be
/// resized at all. Moving all of it out here is what makes "every node resizes,
/// and every node links" one sentence instead of five.
///
/// It draws in screen space and is deliberately **not** scaled by the zoom: a
/// handle is chrome about the camera, not content in the world, and a handle
/// that shrinks with the board is ungrabbable exactly when you most need it.
struct NodeFrame: View {
    /// The node's rectangle, already projected into canvas space.
    var rect: CGRect
    /// Only for the corner radius: the frame itself is chrome and does not
    /// scale, but the curve it has to meet does.
    var zoom: Zoom
    var isSelected: Bool
    /// True while this node is one of several selected: the frame still says
    /// what is yours, but nothing on it resizes.
    var isGroup: Bool
    /// The edge the pointer is nearest, if it is near one at all. The link
    /// handles follow the pointer rather than the selection, so a node you have
    /// never clicked still offers them.
    var hoveredEdge: NodeEdge?
    /// The edge a link is currently being pulled from, which stays lit for the
    /// whole drag even as the pointer leaves the node.
    var linkingFrom: NodeEdge?
    /// Lit when a link being dragged from somewhere else would land here.
    var isDropTarget: Bool
    /// Said instead of the ring when the link already exists — `store.link`
    /// refuses a duplicate silently, and a silent refusal reads as a bug.
    var isAlreadyLinked: Bool
    /// The handle being dragged right now, if it is one of this node's. It
    /// stays on screen even when the node has grown too small for it to be
    /// drawn otherwise: a handle taken out from under the pointer cancels its
    /// own drag.
    var activeHandle: NodeHandle?

    /// Translation in canvas points, and whether the gesture has ended.
    var onResize: (NodeHandle, CGSize, Bool) -> Void
    /// Where the pointer is in canvas space, and whether the gesture has ended.
    var onLink: (NodeEdge, CGPoint, Bool) -> Void

    /// How far outside the node the frame and its handles sit, so they never
    /// cover the node's own border or the first column of a terminal.
    private static let inset = CanvasGeometry.frameInset

    private var fit: CanvasGeometry.HandleFit { .init(rect) }

    /// The frame's own corner: the node's, as it is actually drawn at this
    /// zoom, plus the gap the frame sits out by. Concentric — see
    /// `Theme.Corner`. A flat number here is parallel down the sides and
    /// wrong at every corner.
    private var framedCorner: CGFloat { zoom.s(Theme.Corner.node) + Self.inset }
    private var framed: CGRect { rect.insetBy(dx: -Self.inset, dy: -Self.inset) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isSelected { selectionFrame }
            if isDropTarget { dropRing }
            // Handles only on a node that is the whole selection. Scaling a
            // group of four terminals from one corner is four grid reflows
            // from one gesture, for something nobody arranging agents has
            // asked for — and the absence of handles says so, where a frame
            // with handles that only resized one member would not.
            if isSelected, !isGroup {
                ForEach(handles, id: \.self) { handle in
                    resizeHandle(handle)
                }
            }
            // Link handles are a property of hovering, not of selecting: the
            // thing people do first is move the pointer at a node.
            if linkHandlesVisible {
                ForEach(NodeEdge.allCases, id: \.self) { edge in
                    linkHandle(edge)
                }
            }
        }
        // No `contentShape` and no background: this is an overlay over a live
        // terminal or a web page, and only the handles drawn on it may take a
        // click. Everything between them has to reach the page.

    }

    private var handles: [NodeHandle] {
        var shown = fit.handles
        if let activeHandle, !shown.contains(activeHandle) { shown.append(activeHandle) }
        return shown
    }

    private var linkHandlesVisible: Bool {
        // Not mid-resize: the node is moving under them, and a + sliding along
        // with the edge you are dragging is noise.
        guard fit.showsLinkHandles, activeHandle == nil else { return false }
        return hoveredEdge != nil || linkingFrom != nil
    }

    // MARK: Frame

    private var selectionFrame: some View {
        RoundedRectangle(cornerRadius: framedCorner, style: .continuous)
            .stroke(
                Theme.accent,
                style: StrokeStyle(lineWidth: 1.5, dash: isGroup ? [5, 4] : [])
            )
            .frame(width: framed.width, height: framed.height)
            .position(x: framed.midX, y: framed.midY)
            .allowsHitTesting(false)
    }

    private var dropRing: some View {
        RoundedRectangle(cornerRadius: framedCorner, style: .continuous)
            .stroke(
                isAlreadyLinked ? Theme.textTertiary : Theme.sidechain,
                style: StrokeStyle(lineWidth: 2, dash: isAlreadyLinked ? [4, 3] : [])
            )
            .frame(width: framed.width, height: framed.height)
            .position(x: framed.midX, y: framed.midY)
            .overlay(alignment: .top) {
                if isAlreadyLinked {
                    Text("already linked")
                        .font(Theme.ui(9, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.surfaceRaised))
                        .position(x: framed.midX, y: framed.minY - 10)
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: Handles

    private func resizeHandle(_ handle: NodeHandle) -> some View {
        let centre = handle.point(in: framed)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.surfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 1.5)
            )
            .frame(width: CanvasGeometry.handleSize, height: CanvasGeometry.handleSize)
            // The target is nearly twice what it draws. A 9pt square is a 9pt
            // square, and the pointer is not that precise.
            .frame(width: CanvasGeometry.handleTouch, height: CanvasGeometry.handleTouch)
            .contentShape(Rectangle())
            .position(x: centre.x, y: centre.y)
            .pointer(Pointer.resize(handle))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(CanvasView.canvasSpace))
                    .onChanged { onResize(handle, $0.translation, false) }
                    .onEnded { onResize(handle, $0.translation, true) }
            )
    }

    private func linkHandle(_ edge: NodeEdge) -> some View {
        let anchor = edge.anchor(in: framed)
        let centre = CGPoint(
            x: anchor.x + edge.outward.width * CanvasGeometry.linkOffset,
            y: anchor.y + edge.outward.height * CanvasGeometry.linkOffset
        )
        // The one you are reaching for is solid; the other three are faint —
        // present enough to teach that there are four, quiet enough not to
        // compete with the one under the pointer.
        let isNearest = (linkingFrom ?? hoveredEdge) == edge
        return Image(systemName: "plus")
            .font(Theme.ui(8, .black))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Theme.sidechain))
            .overlay(Circle().stroke(Theme.canvasDeep.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .opacity(isNearest ? 1 : 0.35)
            .frame(width: CanvasGeometry.linkTouch, height: CanvasGeometry.linkTouch)
            .contentShape(Circle())
            .position(x: centre.x, y: centre.y)
            .pointer(Pointer.draw)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(CanvasView.canvasSpace))
                    .onChanged { onLink(edge, $0.location, false) }
                    .onEnded { onLink(edge, $0.location, true) }
            )
            .help("Drag onto another node: what this one is doing becomes context for that one")
    }
}

/// The band a node is picked up by, as a shape — the part of it that shows an
/// open hand before you press.
///
/// A card has no live content to protect, so the whole of it is the band. A
/// terminal or a page keeps everything but a strip around three of its sides;
/// the fourth is its header, which is left alone because the buttons in it
/// need the clicks and the cursor more than the hint does.
struct GrabRing: Shape {
    var band: CGFloat
    var whole: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !whole else { path.addRect(rect); return path }
        guard rect.width > band * 2, rect.height > band else { return path }
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: band, height: rect.height))
        path.addRect(CGRect(x: rect.maxX - band, y: rect.minY, width: band, height: rect.height))
        path.addRect(CGRect(x: rect.minX, y: rect.maxY - band, width: rect.width, height: band))
        return path
    }
}
