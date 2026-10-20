import AppState
import DesignSystem
import MeshvyModels
import SwiftUI

/// The tool palette, floating at the bottom of the board.
///
/// It replaces the two things nobody could find: that ⌘ turned a drag into a
/// new agent, and that the only way to put a shell or a browser on the board
/// was a menu bar two levels deep. A palette says what a drag will do before
/// you do it, and it is the first thing anyone who has used a canvas app looks
/// for.
///
/// Bottom-centre rather than Excalidraw's top-centre: the top bar here already
/// carries the workspace menu, the start button, the agent settings and the
/// zoom cluster, and a board grows down and to the right from its origin, so
/// this is the strip of canvas most likely to be empty.
struct CanvasToolbar: View {
    @Bindable var store: MeshvyStore

    /// Space between the palette's edge and the tools in it. Named because the
    /// tools' own corner is derived from it — see `Theme.Corner`.
    private static let inset: CGFloat = 3
    private static let toolCorner = Theme.Corner.panel - inset

    var body: some View {
        HStack(spacing: 2) {
            item(.select)
            item(.hand)
            divider
            item(.agent)
            item(.shell)
            item(.browser)
        }
        .padding(Self.inset)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairlineStrong)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private func item(_ tool: BoardTool) -> some View {
        let isActive = store.tool == tool
        return Button { store.use(tool) } label: {
            Image(systemName: tool.icon)
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                // Room for the key in the corner without it printing over the
                // glyph: the icon keeps the middle, the letter gets the inch
                // below it.
                .offset(y: -3)
                .frame(width: 34, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Self.toolCorner, style: .continuous)
                        .fill(isActive ? Theme.accent.opacity(0.16) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.toolCorner, style: .continuous)
                        .stroke(isActive ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.label) (\(String(tool.key).uppercased())) — \(tool.hint)")
        .overlay(alignment: .bottomTrailing) {
            // The key, on the tool itself. A shortcut you can only find in a
            // sheet is a shortcut most people never find.
            Text(String(tool.key).uppercased())
                .font(Theme.mono(6.5, .bold))
                .foregroundStyle(isActive ? Theme.accent.opacity(0.75) : Theme.textTertiary.opacity(0.8))
                .padding(.trailing, 4)
                .padding(.bottom, 2)
        }
    }
}

/// What is selected, and what can be done to all of it at once.
///
/// Only ever on screen with more than one node selected: with one, everything
/// here is already in the inspector and on the node itself.
struct SelectionBar: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        HStack(spacing: 8) {
            Text("\(store.selected.count) selected")
                .font(Theme.ui(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 14)
            action("rectangle.3.offgrid", "Line them up", store.tidySelection)
            action("square.on.square", "Bring to front", store.bringSelectionToFront)
            action("xmark", "Close them (⌘⌫)", store.requestRemoveSelection)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Corner.panel, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 5)
    }

    private func action(_ icon: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(Theme.ui(10.5, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
