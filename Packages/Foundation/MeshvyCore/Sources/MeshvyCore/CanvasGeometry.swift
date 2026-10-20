import CoreGraphics
import Foundation

/// The geometry of handling a node: where you take hold of it, what that does
/// to its frame, and what it lines up with on the way.
///
/// All of it is pure arithmetic on rectangles, deliberately kept out of the
/// view layer. The canvas has three separate consumers of the same answers —
/// the gesture that resizes, the overlay that draws the handles, and the hit
/// test that decides which of the two a press belongs to — and when those three
/// each worked it out for themselves they disagreed. The bug that cost most was
/// exactly that: `chromeHeight(of:)` in the canvas had to match a header height
/// in each node view by hand, so a card you could see the grab bar on was not
/// always a card you could pick up.
public enum CanvasGeometry {
    /// Side of a resize handle, in screen points, before zoom.
    ///
    /// 9pt draws as a dot you can see without it covering the content under it;
    /// `handleTouch` is what you actually have to hit.
    public static let handleSize: CGFloat = 9
    /// Hit area of a resize handle, in screen points. Bigger than it draws,
    /// because a 9pt target is a 9pt target and the pointer is not precise.
    public static let handleTouch: CGFloat = 16
    /// How far inside its own edge a node can be grabbed to move it. This is
    /// the band that makes every node draggable without stealing a click from
    /// a terminal or a web page in the middle of one.
    public static let borderGrab: CGFloat = 7
    /// How far outside a node's edge the pointer still counts as "on the edge",
    /// for the link handles. Generous, because this is the gesture the user
    /// asked to be easy.
    public static let edgeReach: CGFloat = 22
    /// Alignment guides catch within this many screen points. Converted to
    /// world units by the caller, so the pull feels the same at every zoom.
    public static let snapThreshold: CGFloat = 7
    /// How far outside a node's frame the selection frame — and so every
    /// resize handle — is drawn.
    public static let frameInset: CGFloat = 4
    /// How far outside the frame a link handle sits, and how big its target is.
    ///
    /// These two and `handleTouch` are load-bearing together. Both handles sit
    /// on the same point of the same edge, measured from the selection frame: a
    /// side resize handle claims `0 ± handleTouch/2`, a link handle claims
    /// `linkOffset ± linkTouch/2`. They must not overlap, because the one
    /// tested first would swallow the other — and the one that loses is
    /// whichever the user was reaching for. `handlesAreDisjoint` is the
    /// arithmetic, and `CanvasGeometryTests` fails if it stops holding; do not
    /// re-pick these numbers without it.
    public static let linkOffset: CGFloat = 20
    public static let linkTouch: CGFloat = 20

    /// Whether the resize handles and the link handles on an edge can both be
    /// aimed at. False means someone has changed a constant above.
    public static var handlesAreDisjoint: Bool {
        handleTouch / 2 < linkOffset - linkTouch / 2
    }

    /// How much of a selection frame is worth drawing at this size — and so
    /// how much of it can be hit.
    ///
    /// Keyed off the *projected* rectangle rather than the zoom, because what
    /// matters is how big the node is on screen: a 780pt workspace node at 20%
    /// is still 156pt and has room for eight handles, while a 256pt sub-agent
    /// card at the same zoom is 51pt and does not. It lives here rather than in
    /// the view because the hit test needs the same answer the painter used.
    public enum HandleFit: Sendable {
        case all, cornersOnly, none

        public init(_ rect: CGRect) {
            if rect.width >= 72, rect.height >= 56 { self = .all }
            else if rect.width >= 34, rect.height >= 28 { self = .cornersOnly }
            else { self = .none }
        }

        public var handles: [NodeHandle] {
            switch self {
            case .all: return NodeHandle.allCases
            case .cornersOnly: return NodeHandle.allCases.filter(\.isCorner)
            case .none: return []
            }
        }

        /// Below this a node is too small on screen to aim at an edge of, so
        /// it offers no link handles either.
        public var showsLinkHandles: Bool { self != .none }
    }

    // MARK: - Resizing

    /// Applies a drag on `handle` to `rect`, in the same coordinate space.
    ///
    /// Clamped rather than mirrored: dragging the left edge past the right one
    /// stops at the minimum width instead of turning the node inside out, so
    /// there is no moment where a PTY is handed a negative size.
    public static func resize(
        _ rect: CGRect, from handle: NodeHandle, by delta: CGSize, minimum: CGSize
    ) -> CGRect {
        var result = rect
        if handle.movesLeftEdge {
            let shift = min(delta.width, rect.width - minimum.width)
            result.origin.x += shift
            result.size.width -= shift
        }
        if handle.movesRightEdge {
            result.size.width = max(minimum.width, rect.width + delta.width)
        }
        if handle.movesTopEdge {
            let shift = min(delta.height, rect.height - minimum.height)
            result.origin.y += shift
            result.size.height -= shift
        }
        if handle.movesBottomEdge {
            result.size.height = max(minimum.height, rect.height + delta.height)
        }
        return result
    }

    /// Which resize handle a point is on, topmost-priority first.
    ///
    /// Corners are tested before sides: at a corner both answers are true, and
    /// the corner is the one that does what the pointer there looks like it will.
    public static func handle(
        at point: CGPoint, of rect: CGRect, touch: CGFloat = handleTouch
    ) -> NodeHandle? {
        let half = touch / 2
        for candidate in NodeHandle.hitOrder {
            let centre = candidate.point(in: rect)
            if abs(point.x - centre.x) <= half, abs(point.y - centre.y) <= half { return candidate }
        }
        return nil
    }

    /// Whether a point is in the band just inside a node's edge — the part of
    /// any node, live content or not, that moves it.
    public static func isOnBorder(
        _ point: CGPoint, of rect: CGRect, band: CGFloat = borderGrab
    ) -> Bool {
        guard rect.contains(point) else { return false }
        return !rect.insetBy(dx: band, dy: band).contains(point)
    }

    /// Which edge of a node the pointer is closest to while within reach of it,
    /// or nil when it is nowhere near one. This is what makes a link handle
    /// appear: you move towards the edge you mean, and it is already there.
    ///
    /// Only the edge regions count, not the corners — a corner belongs to the
    /// resize handle sitting on it, which is the gesture with the smaller target
    /// and so the one that must win.
    public static func edge(
        at point: CGPoint, of rect: CGRect, reach: CGFloat = edgeReach, corner: CGFloat = handleTouch
    ) -> NodeEdge? {
        let outer = rect.insetBy(dx: -reach, dy: -reach)
        guard outer.contains(point) else { return nil }
        // Inside the node proper, only a band near the edge arms a link; deeper
        // in belongs to the content. The band is capped at a third of the node
        // so a small one still has a middle: `insetBy` on a rect narrower than
        // twice the reach produces a negative width, which contains nothing, so
        // every point in a 40pt node used to count as being on an edge.
        let inner = rect.insetBy(
            dx: min(reach, rect.width / 3), dy: min(reach, rect.height / 3)
        )
        if inner.contains(point) { return nil }

        let distances: [(NodeEdge, CGFloat)] = [
            (.top, abs(point.y - rect.minY)),
            (.bottom, abs(point.y - rect.maxY)),
            (.left, abs(point.x - rect.minX)),
            (.right, abs(point.x - rect.maxX))
        ]
        guard let (nearest, _) = distances.min(by: { $0.1 < $1.1 }) else { return nil }
        // A press within a corner's square is the resize handle's, so the edge
        // regions stop short of them.
        if handle(at: point, of: rect, touch: corner)?.isCorner == true { return nil }
        return nearest
    }

    // MARK: - Snapping

    /// What a dragged frame lined up with, and the guides to draw for it.
    public struct Snap: Equatable, Sendable {
        /// Adjustment to add to the proposed origin.
        public var offset: CGSize
        /// World x of each vertical guide, and world y of each horizontal one.
        public var verticals: [CGFloat]
        public var horizontals: [CGFloat]

        public static let none = Snap(offset: .zero, verticals: [], horizontals: [])

        public init(offset: CGSize, verticals: [CGFloat], horizontals: [CGFloat]) {
            self.offset = offset
            self.verticals = verticals
            self.horizontals = horizontals
        }

        public var isEmpty: Bool { verticals.isEmpty && horizontals.isEmpty }
    }

    /// Pulls `rect` into line with the nearest of `others` on each axis.
    ///
    /// Edges and centres, which is the whole of what makes a hand-arranged
    /// board look arranged: two cards share a top, or a column shares a centre
    /// line. Equal-spacing guides are deliberately not here — they are the next
    /// thing you want and the first thing that gets in the way, because they
    /// fire on triples the user never meant to relate.
    public static func snap(
        _ rect: CGRect, to others: [CGRect], within threshold: CGFloat
    ) -> Snap {
        guard threshold > 0, !others.isEmpty else { return .none }

        var bestX: (delta: CGFloat, guide: CGFloat)?
        var bestY: (delta: CGFloat, guide: CGFloat)?
        let mine = [rect.minX, rect.midX, rect.maxX]
        let myY = [rect.minY, rect.midY, rect.maxY]

        for other in others {
            for theirs in [other.minX, other.midX, other.maxX] {
                for value in mine where abs(theirs - value) <= threshold {
                    let delta = theirs - value
                    if bestX == nil || abs(delta) < abs(bestX!.delta) { bestX = (delta, theirs) }
                }
            }
            for theirs in [other.minY, other.midY, other.maxY] {
                for value in myY where abs(theirs - value) <= threshold {
                    let delta = theirs - value
                    if bestY == nil || abs(delta) < abs(bestY!.delta) { bestY = (delta, theirs) }
                }
            }
        }

        return Snap(
            offset: CGSize(width: bestX?.delta ?? 0, height: bestY?.delta ?? 0),
            verticals: bestX.map { [$0.guide] } ?? [],
            horizontals: bestY.map { [$0.guide] } ?? []
        )
    }
}

/// A corner or side of a node, as something to resize it by.
public enum NodeHandle: String, CaseIterable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Corners before sides: both answer true at a corner, and the corner is
    /// what the pointer there looks like it will do.
    public static let hitOrder: [NodeHandle] = [
        .topLeft, .topRight, .bottomLeft, .bottomRight, .top, .bottom, .left, .right
    ]

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    public var movesLeftEdge: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: return true
        default: return false
        }
    }

    public var movesRightEdge: Bool {
        switch self {
        case .topRight, .right, .bottomRight: return true
        default: return false
        }
    }

    public var movesTopEdge: Bool {
        switch self {
        case .topLeft, .top, .topRight: return true
        default: return false
        }
    }

    public var movesBottomEdge: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: return true
        default: return false
        }
    }

    /// Position within a unit square, so one expression places the handle on
    /// any rect at any zoom.
    public var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        }
    }

    public func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * unit.x, y: rect.minY + rect.height * unit.y)
    }

    /// Which way the pointer should say it is about to stretch something.
    /// macOS ships no diagonal resize cursor in the public API, so the corners
    /// borrow the axis they move furthest along; a wrong-looking cursor is a
    /// smaller lie than no cursor at all.
    public var cursorAxis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        default: return .diagonal
        }
    }

    public enum Axis: Sendable { case horizontal, vertical, diagonal }
}

/// A side of a node, as the place a link is pulled out of.
public enum NodeEdge: String, CaseIterable, Hashable, Sendable {
    case top, right, bottom, left

    /// Midpoint of the side, where the handle draws.
    public func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Unit vector pointing away from the node, so a handle can sit just off
    /// the edge rather than on top of its own border.
    public var outward: CGSize {
        switch self {
        case .top: return CGSize(width: 0, height: -1)
        case .right: return CGSize(width: 1, height: 0)
        case .bottom: return CGSize(width: 0, height: 1)
        case .left: return CGSize(width: -1, height: 0)
        }
    }
}
