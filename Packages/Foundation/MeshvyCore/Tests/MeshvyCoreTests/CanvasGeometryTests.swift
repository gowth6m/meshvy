import CoreGraphics
import Testing

@testable import MeshvyCore

@Suite("Canvas geometry")
struct CanvasGeometryTests {
    private let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let minimum = CGSize(width: 120, height: 90)

    // MARK: Resizing

    @Test("dragging the bottom-right corner grows the node and leaves its origin alone")
    func growFromBottomRight() {
        let out = CanvasGeometry.resize(
            rect, from: .bottomRight, by: CGSize(width: 60, height: 40), minimum: minimum
        )
        #expect(out.origin == rect.origin)
        #expect(out.width == 460)
        #expect(out.height == 340)
    }

    @Test("dragging the top-left corner moves the origin and keeps the far edges still")
    func growFromTopLeft() {
        let out = CanvasGeometry.resize(
            rect, from: .topLeft, by: CGSize(width: -50, height: -30), minimum: minimum
        )
        #expect(out.minX == 50)
        #expect(out.minY == 70)
        #expect(out.maxX == rect.maxX)
        #expect(out.maxY == rect.maxY)
    }

    @Test("a side handle moves one edge only")
    func sideHandleIsOneAxis() {
        let out = CanvasGeometry.resize(
            rect, from: .left, by: CGSize(width: 40, height: 999), minimum: minimum
        )
        #expect(out.minX == 140)
        #expect(out.height == rect.height)
        #expect(out.maxX == rect.maxX)
    }

    @Test("a node cannot be turned inside out: the minimum holds and the far edge stays put")
    func minimumClamps() {
        let out = CanvasGeometry.resize(
            rect, from: .topLeft, by: CGSize(width: 10_000, height: 10_000), minimum: minimum
        )
        #expect(out.width == minimum.width)
        #expect(out.height == minimum.height)
        // The edge the user was not dragging must not move, or the node walks
        // across the board as it bottoms out.
        #expect(out.maxX == rect.maxX)
        #expect(out.maxY == rect.maxY)
    }

    @Test("every handle respects the minimum from either direction")
    func everyHandleClamps() {
        for handle in NodeHandle.allCases {
            for delta in [CGSize(width: 9_999, height: 9_999), CGSize(width: -9_999, height: -9_999)] {
                let out = CanvasGeometry.resize(rect, from: handle, by: delta, minimum: minimum)
                #expect(out.width >= minimum.width)
                #expect(out.height >= minimum.height)
            }
        }
    }

    // MARK: Hit testing

    @Test("each handle is found at its own corner or side")
    func handlesHitWhereTheyDraw() {
        for handle in NodeHandle.allCases {
            let found = CanvasGeometry.handle(at: handle.point(in: rect), of: rect)
            #expect(found == handle, "\(handle) was found as \(String(describing: found))")
        }
    }

    @Test("the middle of a node is no handle at all — that is its content")
    func centreIsNotAHandle() {
        #expect(CanvasGeometry.handle(at: rect.center, of: rect) == nil)
    }

    @Test("a corner belongs to the corner handle, not the side it shares an axis with")
    func cornerBeatsSide() {
        let justInside = CGPoint(x: rect.minX + 2, y: rect.minY + 2)
        #expect(CanvasGeometry.handle(at: justInside, of: rect) == .topLeft)
    }

    @Test("the border band moves the node; the content under it does not")
    func borderBand() {
        #expect(CanvasGeometry.isOnBorder(CGPoint(x: rect.midX, y: rect.minY + 2), of: rect))
        #expect(!CanvasGeometry.isOnBorder(rect.center, of: rect))
        // Outside the node is not its border: that press belongs to the board.
        #expect(!CanvasGeometry.isOnBorder(CGPoint(x: rect.midX, y: rect.minY - 3), of: rect))
    }

    @Test("a node smaller than the minimum does not jump when a handle is first dragged")
    func undersizedNodeDoesNotJump() {
        let small = CGRect(x: 100, y: 100, width: 80, height: 60)
        let nudged = CanvasGeometry.resize(
            small, from: .topLeft, by: CGSize(width: 1, height: 1), minimum: minimum
        )
        #expect(nudged == small)
        let grown = CanvasGeometry.resize(
            small, from: .bottomRight, by: CGSize(width: 5, height: 5), minimum: minimum
        )
        #expect(grown.size == CGSize(width: 85, height: 65))
        let pulled = CanvasGeometry.resize(
            small, from: .left, by: CGSize(width: -10, height: 0), minimum: minimum
        )
        #expect(pulled.minX == 90)
        #expect(pulled.width == 90)
    }

    // MARK: Link edges

    @Test("nearing an edge from outside or inside arms that edge")
    func edgeIsReachableFromBothSides() {
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.maxX + 8, y: rect.midY), of: rect) == .right)
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.maxX - 8, y: rect.midY), of: rect) == .right)
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.midX, y: rect.minY - 8), of: rect) == .top)
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.midX, y: rect.maxY + 8), of: rect) == .bottom)
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.minX - 8, y: rect.midY), of: rect) == .left)
    }

    @Test("the middle of a node arms no edge, and neither does the far field")
    func edgeNeedsProximity() {
        #expect(CanvasGeometry.edge(at: rect.center, of: rect) == nil)
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.maxX + 400, y: rect.midY), of: rect) == nil)
    }

    @Test("the hover reaches all the way across a link handle, so it cannot vanish under the pointer")
    func hoverCoversTheLinkHandle() {
        let outerEdge = CanvasGeometry.frameInset + CanvasGeometry.linkOffset + CanvasGeometry.linkTouch / 2
        #expect(CanvasGeometry.linkReach > outerEdge)
        let onHandle = CGPoint(x: rect.maxX + outerEdge - 1, y: rect.midY)
        #expect(CanvasGeometry.edge(at: onHandle, of: rect) == .right)
    }

    @Test("a corner is the resize handle's, so no link starts there")
    func cornerIsNotAnEdge() {
        #expect(CanvasGeometry.edge(at: CGPoint(x: rect.maxX, y: rect.maxY), of: rect) == nil)
    }

    @Test("a node too small to have a middle still has one, for the link handles")
    func smallRectStillHasAMiddle() {
        // `insetBy` on a rect narrower than twice the reach produces a negative
        // width, which contains nothing — so every point in a small node used
        // to read as being on one of its edges.
        let small = CGRect(x: 0, y: 0, width: 40, height: 40)
        #expect(CanvasGeometry.edge(at: small.center, of: small) == nil)
        #expect(CanvasGeometry.edge(at: CGPoint(x: small.maxX + 4, y: small.midY), of: small) == .right)
    }

    @Test("a resize handle and a link handle on the same edge cannot overlap")
    func handleTargetsAreDisjoint() {
        // They sit on the same point of the same side, and both want a
        // generous target. Whichever is hit-tested first would swallow the
        // other, and the one that loses is whichever the user was reaching for.
        #expect(CanvasGeometry.handlesAreDisjoint)
        let framed = rect.insetBy(dx: -CanvasGeometry.frameInset, dy: -CanvasGeometry.frameInset)
        let resizeEdge = framed.maxX + CanvasGeometry.handleTouch / 2
        let linkEdge = framed.maxX + CanvasGeometry.linkOffset - CanvasGeometry.linkTouch / 2
        #expect(resizeEdge < linkEdge)
    }

    @Test("how much of a frame fits is decided by the size on screen, not the zoom")
    func handleFit() {
        // A session card is 268×132. At 35% it is 94×46 on screen, which has
        // room for corners but not for eight; a sub-agent card at 12% has room
        // for neither.
        #expect(CanvasGeometry.HandleFit(CGRect(x: 0, y: 0, width: 780, height: 520)) == .all)
        let card = CGRect(x: 0, y: 0, width: 268 * 0.35, height: 132 * 0.35)
        #expect(CanvasGeometry.HandleFit(card) == .cornersOnly)
        #expect(CanvasGeometry.HandleFit(card).handles.count == 4)
        let tiny = CGRect(x: 0, y: 0, width: 256 * 0.12, height: 108 * 0.12)
        #expect(CanvasGeometry.HandleFit(tiny) == .none)
        #expect(!CanvasGeometry.HandleFit(tiny).showsLinkHandles)
    }

    @Test("an edge anchor sits on the middle of its side")
    func anchors() {
        #expect(NodeEdge.right.anchor(in: rect) == CGPoint(x: rect.maxX, y: rect.midY))
        #expect(NodeEdge.top.anchor(in: rect) == CGPoint(x: rect.midX, y: rect.minY))
    }

    // MARK: Snapping

    @Test("a frame within the threshold is pulled into line, and says which line")
    func snapsToSharedEdge() {
        let other = CGRect(x: 600, y: 104, width: 200, height: 200)
        let snap = CanvasGeometry.snap(rect, to: [other], within: 7)
        #expect(snap.offset.height == 4)
        #expect(snap.offset.width == 0)
        #expect(snap.horizontals == [104])
        #expect(snap.verticals.isEmpty)
    }

    @Test("centres line up as well as edges")
    func snapsToCentre() {
        // The other node's centre x is 3pt from this one's, and no edge of it
        // is anywhere near an edge of this one — so the centre is the only
        // candidate and the guide drawn has to be the centre line.
        let other = CGRect(x: 253, y: 900, width: 100, height: 100)
        let snap = CanvasGeometry.snap(rect, to: [other], within: 7)
        #expect(snap.offset.width == 3)
        #expect(snap.verticals == [other.midX])
    }

    @Test("nothing within reach means nothing moves")
    func noSnap() {
        let far = CGRect(x: 2_000, y: 2_000, width: 100, height: 100)
        let snap = CanvasGeometry.snap(rect, to: [far], within: 7)
        #expect(snap == CanvasGeometry.Snap.none)
        #expect(snap.isEmpty)
    }

    @Test("the nearest candidate wins, so a crowded board does not jump to the far one")
    func nearestWins() {
        let near = CGRect(x: 102, y: 900, width: 100, height: 100)
        let alsoNear = CGRect(x: 95, y: 900, width: 100, height: 100)
        let snap = CanvasGeometry.snap(rect, to: [alsoNear, near], within: 7)
        #expect(snap.offset.width == 2)
    }

    @Test("a zero threshold disables snapping entirely")
    func thresholdOff() {
        let other = CGRect(x: 100, y: 104, width: 200, height: 200)
        #expect(CanvasGeometry.snap(rect, to: [other], within: 0) == CanvasGeometry.Snap.none)
    }
}
