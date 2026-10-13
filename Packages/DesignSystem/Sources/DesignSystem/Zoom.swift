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

    public func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.ui(max(1, size * typeScale), weight)
    }

    public func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.mono(max(1, size * typeScale), weight)
    }
}
