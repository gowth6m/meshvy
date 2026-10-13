import CoreGraphics
import Foundation

/// Camera over the infinite canvas. Canvas coordinates are "world" units;
/// everything drawn on screen is derived through `project(_:)`.
public struct Viewport: Equatable {
    /// World point currently pinned to the centre of the visible area.
    public var center: CGPoint = .zero
    public var scale: CGFloat = 1.0
    /// Size of the visible area in screen points. Updated by the canvas on layout.
    public var size: CGSize = .zero

    public init(
        center: CGPoint = .zero,
        scale: CGFloat = 1.0,
        size: CGSize = .zero
    ) {
        self.center = center
        self.scale = scale
        self.size = size
    }

    public static let minScale: CGFloat = 0.08
    public static let maxScale: CGFloat = 3.0

    public var screenCenter: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    public func project(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: (world.x - center.x) * scale + screenCenter.x,
            y: (world.y - center.y) * scale + screenCenter.y
        )
    }

    public func project(_ rect: CGRect) -> CGRect {
        let origin = project(rect.origin)
        return CGRect(origin: origin, size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    public func unproject(_ screen: CGPoint) -> CGPoint {
        CGPoint(
            x: (screen.x - screenCenter.x) / scale + center.x,
            y: (screen.y - screenCenter.y) / scale + center.y
        )
    }

    public var hasSize: Bool { size.width > 0 && size.height > 0 }

    /// World rectangle currently visible, padded so nodes straddling the edge
    /// still draw. Empty before the canvas has been laid out — callers use this
    /// for culling, and culling everything is correct when nothing is on screen
    /// yet.
    public func visibleWorldRect(padding: CGFloat = 240) -> CGRect {
        guard hasSize else { return .zero }
        let topLeft = unproject(.zero)
        let bottomRight = unproject(CGPoint(x: size.width, y: size.height))
        return CGRect(
            x: topLeft.x - padding,
            y: topLeft.y - padding,
            width: (bottomRight.x - topLeft.x) + padding * 2,
            height: (bottomRight.y - topLeft.y) + padding * 2
        )
    }

    /// Zoom about a fixed screen point so content under the cursor stays put.
    public mutating func zoom(to newScale: CGFloat, anchor: CGPoint) {
        let clamped = min(max(newScale, Self.minScale), Self.maxScale)
        guard clamped != scale else { return }
        let worldAnchor = unproject(anchor)
        scale = clamped
        let drifted = unproject(anchor)
        center.x += worldAnchor.x - drifted.x
        center.y += worldAnchor.y - drifted.y
    }

    public mutating func pan(by delta: CGSize) {
        center.x -= delta.width / scale
        center.y -= delta.height / scale
    }

    /// Frame a world rectangle with margin, clamping to the allowed zoom range.
    public mutating func fit(_ rect: CGRect, margin: CGFloat = 80) {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return }
        let sx = (size.width - margin * 2) / rect.width
        let sy = (size.height - margin * 2) / rect.height
        scale = min(max(min(sx, sy), Self.minScale), Self.maxScale)
        center = CGPoint(x: rect.midX, y: rect.midY)
    }
}

/// Zoom thresholds that drive how much detail a node renders. Keeps a few
/// hundred nodes cheap when the whole graph is in frame.
public enum DetailLevel: Int, Comparable {
    case block = 0   // solid swatch, no text
    case compact = 1 // title + status only
    case full = 2    // everything

    public init(scale: CGFloat) {
        if scale < 0.3 { self = .block }
        else if scale < 0.62 { self = .compact }
        else { self = .full }
    }

    public static func < (lhs: DetailLevel, rhs: DetailLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension CGRect {
    /// Union of all rects, or nil when the sequence is empty.
    public static func bounding(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Point on the rect edge nearest `target`, used to dock edge endpoints.
    public func anchor(towards target: CGPoint) -> CGPoint {
        let dx = target.x - midX
        let dy = target.y - midY
        guard dx != 0 || dy != 0 else { return center }
        if abs(dx) * height > abs(dy) * width {
            let x = dx > 0 ? maxX : minX
            let y = midY + dy * (width / 2) / abs(dx)
            return CGPoint(x: x, y: min(max(y, minY), maxY))
        } else {
            let y = dy > 0 ? maxY : minY
            let x = midX + dx * (height / 2) / abs(dy)
            return CGPoint(x: min(max(x, minX), maxX), y: y)
        }
    }
}
