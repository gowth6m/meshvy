import AppKit
import SwiftUI

/// Draggable divider between a side panel and the canvas.
///
/// The hit area is wider than the visible line so it is easy to grab, and the
/// cursor flips to the resize arrows on hover.
struct ResizeHandle: View {
    enum Edge {
        /// Panel is to the left of the handle; dragging right widens it.
        case leading
        /// Panel is to the right; dragging left widens it.
        case trailing
    }

    var edge: Edge
    var width: Binding<Double>
    var range: ClosedRange<Double>
    var onCommit: () -> Void

    @State private var startWidth: Double?
    @State private var hovering = false
    @State private var pushedCursor = false

    /// Pushes and pops exactly once, so the cursor cannot get stuck if the
    /// handle disappears while the pointer is over it.
    private func setCursor(_ active: Bool) {
        guard active != pushedCursor else { return }
        pushedCursor = active
        if active { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }

    var body: some View {
        Rectangle()
            .fill(hovering ? Theme.accent.opacity(0.5) : Theme.hairline)
            .frame(width: 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                setCursor(inside)
            }
            .onDisappear { setCursor(false) }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? width.wrappedValue
                        if startWidth == nil { startWidth = start }
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        width.wrappedValue = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        onCommit()
                    }
            )
    }
}
