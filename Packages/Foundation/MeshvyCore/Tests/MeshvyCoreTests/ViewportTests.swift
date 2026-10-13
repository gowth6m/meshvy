import CoreGraphics
import Testing

@testable import MeshvyCore

@Suite("Viewport")
struct ViewportTests {
    private func sized(_ width: CGFloat = 1000, _ height: CGFloat = 800) -> Viewport {
        var viewport = Viewport()
        viewport.size = CGSize(width: width, height: height)
        return viewport
    }

    @Test("projecting and unprojecting a point is a round trip")
    func roundTrip() {
        var viewport = sized()
        viewport.center = CGPoint(x: 120, y: -40)
        viewport.scale = 1.7
        let world = CGPoint(x: 310, y: 55)
        let back = viewport.unproject(viewport.project(world))
        #expect(abs(back.x - world.x) < 0.0001)
        #expect(abs(back.y - world.y) < 0.0001)
    }

    @Test("the world point under the cursor does not move while zooming")
    func zoomKeepsAnchorStill() {
        var viewport = sized()
        let anchor = CGPoint(x: 220, y: 640)
        let before = viewport.unproject(anchor)
        viewport.zoom(to: 2.4, anchor: anchor)
        let after = viewport.unproject(anchor)
        #expect(abs(before.x - after.x) < 0.0001)
        #expect(abs(before.y - after.y) < 0.0001)
    }

    @Test("zoom clamps to the allowed range")
    func zoomClamps() {
        var viewport = sized()
        viewport.zoom(to: 99, anchor: .zero)
        #expect(viewport.scale == Viewport.maxScale)
        viewport.zoom(to: 0.0001, anchor: .zero)
        #expect(viewport.scale == Viewport.minScale)
    }

    @Test("panning moves the centre against the gesture, in world units")
    func panIsScaled() {
        var viewport = sized()
        viewport.scale = 2
        viewport.pan(by: CGSize(width: 100, height: 50))
        #expect(viewport.center.x == -50)
        #expect(viewport.center.y == -25)
    }

    @Test("fitting a rect centres it and stays inside the zoom range")
    func fitCentres() {
        var viewport = sized()
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        viewport.fit(rect)
        #expect(viewport.center == CGPoint(x: rect.midX, y: rect.midY))
        #expect(viewport.scale <= Viewport.maxScale)
        #expect(viewport.scale >= Viewport.minScale)
    }

    @Test("an enormous rect still clamps rather than zooming out past the minimum")
    func fitClampsTiny() {
        var viewport = sized()
        viewport.fit(CGRect(x: 0, y: 0, width: 1_000_000, height: 1_000_000))
        #expect(viewport.scale == Viewport.minScale)
    }

    @Test("fit ignores a degenerate rect instead of producing a NaN scale")
    func fitIgnoresEmpty() {
        var viewport = sized()
        viewport.scale = 1.25
        viewport.fit(.zero)
        #expect(viewport.scale == 1.25)
    }

    // Culling reads this before the canvas has been laid out, and culling
    // everything is the correct answer when nothing is on screen yet.
    @Test("the visible rect is empty until the canvas has a size")
    func visibleRectNeedsSize() {
        #expect(Viewport().visibleWorldRect() == .zero)
        #expect(sized().visibleWorldRect() != .zero)
    }

    @Test("the visible rect is padded on both sides of each axis")
    func visibleRectPads() {
        let rect = sized(1000, 800).visibleWorldRect(padding: 100)
        #expect(rect.width == 1200)
        #expect(rect.height == 1000)
    }
}

@Suite("DetailLevel")
struct DetailLevelTests {
    @Test("thresholds", arguments: [
        (0.0, DetailLevel.block), (0.29, .block),
        (0.3, .compact), (0.61, .compact),
        (0.62, .full), (3.0, .full),
    ])
    func thresholds(scale: CGFloat, expected: DetailLevel) {
        #expect(DetailLevel(scale: scale) == expected)
    }

    @Test("detail levels order from least to most drawn")
    func ordering() {
        #expect(DetailLevel.block < DetailLevel.compact)
        #expect(DetailLevel.compact < DetailLevel.full)
    }
}

@Suite("CGRect helpers")
struct RectTests {
    @Test("bounding is nil for no rects and the union otherwise")
    func bounding() {
        #expect(CGRect.bounding([]) == nil)
        let union = CGRect.bounding([
            CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 90, y: 40, width: 10, height: 10),
        ])
        #expect(union == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test("an anchor towards a far-off point lands on the rect's edge")
    func anchorOnEdge() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = rect.anchor(towards: CGPoint(x: 10_000, y: 50))
        #expect(right.x == rect.maxX)
        let below = rect.anchor(towards: CGPoint(x: 50, y: 10_000))
        #expect(below.y == rect.maxY)
    }

    @Test("an anchor towards its own centre is the centre")
    func anchorDegenerate() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(rect.anchor(towards: rect.center) == rect.center)
    }
}
