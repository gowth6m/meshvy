import AppKit
import SwiftUI

/// Two stacked panes with a draggable divider between them.
///
/// Used for the file list above the diff: both need room, and how much depends
/// entirely on what you are looking at.
public struct VSplit<Top: View, Bottom: View>: View {
    @ViewBuilder public var top: Top
    @ViewBuilder public var bottom: Bottom

    public init(
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.top = top()
        self.bottom = bottom()
    }

    @State private var topFraction: Double = 0.36
    @State private var dragStart: Double?
    @State private var pushedCursor = false

    public var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let topHeight = max(70, min(height - 110, height * topFraction))

            VStack(spacing: 0) {
                top.frame(height: topHeight)
                divider(totalHeight: height)
                bottom.frame(maxHeight: .infinity)
            }
        }
    }

    /// Pushes and pops exactly once; an unbalanced pair leaves the resize
    /// cursor stuck after the divider goes away.
    private func setCursor(_ active: Bool) {
        guard active != pushedCursor else { return }
        pushedCursor = active
        if active { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }

    private func divider(totalHeight: Double) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .frame(height: 9)
            .contentShape(Rectangle())
            .onHover { inside in setCursor(inside) }
            .onDisappear { setCursor(false) }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? topFraction
                        if dragStart == nil { dragStart = start }
                        guard totalHeight > 0 else { return }
                        topFraction = min(max(start + value.translation.height / totalHeight, 0.12), 0.8)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
