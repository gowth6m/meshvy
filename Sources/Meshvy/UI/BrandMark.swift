import SwiftUI

/// The Meshvy mark: an M drawn as a graph — four quiet nodes, one lit.
///
/// Drawn rather than loaded from the PNG so it stays crisp at any size and
/// picks up the theme. Geometry matches `Resources/brand/mark-on-dark.svg`
/// exactly (viewBox 2 4 44 40).
struct BrandMark: View {
    var size: CGFloat
    var tint: SwiftUI.Color = Theme.markTint
    var accent: SwiftUI.Color = Theme.markAccent

    /// The SVG's viewBox, so the published coordinates can be used verbatim.
    private let box = CGRect(x: 2, y: 4, width: 44, height: 40)

    private var scale: CGFloat { size / box.width }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - box.minX) * scale, y: (y - box.minY) * scale)
    }

    var body: some View {
        Canvas { context, _ in
            var strokes = Path()
            strokes.move(to: point(8, 38))
            strokes.addLine(to: point(8, 10))
            strokes.addLine(to: point(24, 28))
            strokes.addLine(to: point(40, 10))
            strokes.addLine(to: point(40, 38))
            strokes.move(to: point(8, 38))
            strokes.addLine(to: point(24, 28))

            context.stroke(
                strokes,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round)
            )

            for corner in [(8.0, 10.0), (40.0, 10.0), (8.0, 38.0), (40.0, 38.0)] {
                context.fill(circle(at: point(corner.0, corner.1), radius: 3.4 * scale), with: .color(tint))
            }
            context.fill(circle(at: point(24, 28), radius: 4.2 * scale), with: .color(accent))
        }
        .frame(width: size, height: size * (box.height / box.width))
    }

    private func circle(at centre: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: centre.x - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
}
