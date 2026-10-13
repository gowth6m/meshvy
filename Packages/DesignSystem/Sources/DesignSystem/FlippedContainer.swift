import AppKit

/// Hosts one AppKit view laid out from the top-left and magnified by `scale`.
///
/// Both the terminal and the browser put a live `NSView` on the canvas, and
/// both need the card's own top-left origin rather than AppKit's bottom-left.
/// Scaling happens here, on the container's coordinate system, so the hosted
/// view's frame depends only on the node's size — see `TerminalSurface` for
/// why that matters to SwiftTerm.
public final class FlippedContainer: NSView {
    public var scale: CGFloat = 1

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        guard let child = subviews.first else { return }
        guard scale > 0.01, frame.width > 1, frame.height > 1 else {
            child.frame = bounds
            return
        }
        // Scale *this* view's coordinate system rather than the terminal's.
        // The container's frame is the projected rect and its bounds are
        // that rect in world units, so everything inside is magnified by
        // exactly the zoom, in both axes — while the terminal's own frame
        // depends only on the node's size, which is what keeps SwiftTerm
        // from recomputing its grid and making every running program redraw
        // on each zoom step.
        let world = CGSize(width: frame.width / scale, height: frame.height / scale)
        setBoundsSize(world)
        child.frame = CGRect(origin: .zero, size: world)
    }
}
