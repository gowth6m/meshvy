import AppKit
import MeshvyCore
import SwiftUI

/// Says what the pointer is about to do, by changing what it looks like.
///
/// A canvas has no labels on it: the only thing that can tell you the edge of a
/// node resizes and its border moves is the cursor, before you press. This is
/// the one place that is decided, so two overlays cannot disagree about it.
public enum Pointer {
    /// Grab bands and headers. Open while hovering, closed while dragging —
    /// the pair everyone already reads as "you can pick this up".
    public static let move = NSCursor.openHand
    public static let moving = NSCursor.closedHand
    /// Pulling a link out of an edge, and drawing a node with a creation tool.
    public static let draw = NSCursor.crosshair

    /// The cursor for a resize handle.
    ///
    /// macOS 15 finally made the diagonal frame-resize cursors public; before
    /// that the only honest options were the two axis cursors, so a corner
    /// borrows whichever axis it moves along. A cursor that is nearly right is
    /// a smaller lie than no cursor at all.
    public static func resize(_ handle: NodeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch handle {
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        switch handle.cursorAxis {
        case .horizontal, .diagonal: return .resizeLeftRight
        case .vertical: return .resizeUpDown
        }
    }
}

extension View {
    /// Shows `cursor` while the pointer is over this view.
    ///
    /// Pushed and popped exactly once, tracked by a flag rather than by trusting
    /// the hover events to arrive in pairs: a handle can be taken out from under
    /// the pointer — by a node being deselected, by the board rebuilding — and
    /// an unbalanced push leaves the whole app holding a resize cursor.
    public func pointer(_ cursor: NSCursor?, active: Bool = true) -> some View {
        modifier(PointerShape(cursor: cursor, active: active))
    }
}

private struct PointerShape: ViewModifier {
    var cursor: NSCursor?
    var active: Bool

    /// Whether the pointer is inside, and which cursor is actually on the
    /// stack — the instance, not a flag saying one is.
    ///
    /// A flag is not enough. `cursor` can become nil or change while the
    /// pointer is still inside — the board's own cursor does exactly that when
    /// the tool changes under the pointer — and a pop that first has to find a
    /// cursor to pop never happens, which leaves the whole app holding a
    /// crosshair. Keeping both halves of the state and reconciling them in one
    /// place means every path in and out balances, including the one where a
    /// handle is taken out from under the pointer by the board rebuilding.
    @State private var isInside = false
    @State private var pushed: NSCursor?

    func body(content: Content) -> some View {
        content
            .onHover { isInside = $0 }
            .onChange(of: isInside) { _, _ in reconcile() }
            .onChange(of: active) { _, _ in reconcile() }
            .onChange(of: cursor.map(ObjectIdentifier.init)) { _, _ in reconcile() }
            .onDisappear {
                isInside = false
                reconcile()
            }
    }

    private func reconcile() {
        let wanted = isInside && active ? cursor : nil
        guard wanted !== pushed else { return }
        if pushed != nil { NSCursor.pop() }
        pushed = wanted
        wanted?.push()
    }
}
