import SwiftUI

/// Scales a design-time dimension for the current zoom. The canvas renders in
/// screen space rather than using `.scaleEffect`, so text stays crisp at any
/// zoom instead of being rasterised once and stretched.
public struct Zoom {
    /// How much the canvas is magnified. Geometry follows this exactly.
    public let scale: CGFloat

    public init(scale: CGFloat) {
        self.scale = scale
    }

    /// Type does not follow `scale`. Scaled linearly it turns to mush on the
    /// way out and shouts on the way in — at 45% a title is 5pt, at 160% the
    /// same title fills a card that has no more to say. The square root
    /// compresses both ends, and the clamp stops it running away entirely.
    ///
    /// Equal to 1 at 100%, so the board looks unchanged at its resting zoom.
    public var typeScale: CGFloat {
        min(max(sqrt(max(scale, 0.01)), Zoom.minTypeScale), Zoom.maxTypeScale)
    }

    /// Below this the card is small enough that `DetailLevel` has already
    /// dropped to a title and one line, which still fits.
    public static let minTypeScale: CGFloat = 0.8
    public static let maxTypeScale: CGFloat = 1.3

    /// Geometry: paddings, corner radii, card chrome.
    public func s(_ value: CGFloat) -> CGFloat { value * scale }

    /// Type, on the compressed curve.
    public func t(_ value: CGFloat) -> CGFloat { value * typeScale }

    /// Below this, a node stops drawing its live content — a terminal's glyphs
    /// and a web page are both unreadable by then — and shows what it is
    /// instead. Named here because three node views and `Zoom.c` all turn on it.
    public static let liveContentScale: CGFloat = 0.5

    /// Whether this zoom is one at which a node still draws what is inside it.
    public var showsLiveContent: Bool { scale > Zoom.liveContentScale }

    /// A band of chrome that has to hold type: a header, a status strip, an
    /// address bar.
    ///
    /// Two things pull on this number in opposite directions.
    ///
    /// Geometry follows the zoom exactly and type does not, so a header scaled
    /// by `s` eventually becomes shorter than the words in it — at 30% it is
    /// 13pt tall holding 19pt of them, which is why the workspace node's name
    /// used to print across its own branch line.
    ///
    /// But the band's height also decides how much of the node is left for the
    /// live view inside it, and `FlippedContainer` lays that view out at its
    /// *world* size. A band that grows faster than the zoom shrinks the
    /// terminal in world units as you zoom out — so SwiftTerm recomputes its
    /// grid and `SIGWINCH`es the agent on every step of a pinch.
    ///
    /// Both are satisfied by where the two problems live: a node stops drawing
    /// its live content below `liveContentScale`, and type only outgrows its
    /// band below roughly the same point. So above it the band follows the
    /// geometry exactly and the grid never moves; below it the band takes
    /// whichever is larger, and the only thing it can crowd is a placeholder.
    public func c(_ value: CGFloat) -> CGFloat {
        showsLiveContent ? s(value) : max(s(value), t(value))
    }

    public func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.ui(max(1, size * typeScale), weight)
    }

    public func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.mono(max(1, size * typeScale), weight)
    }
}
