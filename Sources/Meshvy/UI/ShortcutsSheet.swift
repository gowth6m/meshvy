import SwiftUI

/// ⌘/ — the keys, in one place.
///
/// A canvas has gestures you cannot discover by looking at it: that the wheel
/// pans, that a terminal takes the wheel once you rest on it, that ⇧⇥ inside a
/// session still cycles its permission mode. This is where those are written
/// down.
struct ShortcutsSheet: View {
    @Bindable var store: MeshvyStore

    private struct Row: Identifiable {
        var keys: String
        var what: String
        var id: String { keys + what }
    }

    private struct Section: Identifiable {
        var title: String
        var rows: [Row]
        var id: String { title }
    }

    private var sections: [Section] {
        [
            Section(title: "Board", rows: [
                Row(keys: "⌘K", what: "Command palette — agents, nodes, terminal output"),
                Row(keys: "⌘F", what: "Find on the board; ⇧⌘F frames the hits"),
                Row(keys: "⇧⌘N", what: "New workspace"),
                Row(keys: "⇧⌘O", what: "Add repositories"),
                Row(keys: "⌘R", what: "Refresh everything; ⇧⌘R git only"),
                Row(keys: "⌘/", what: "This list")
            ]),
            Section(title: "Agents", rows: [
                Row(keys: "⇧⌘T", what: "Start or focus the orchestrator"),
                Row(keys: "⌘T", what: "New shell"),
                Row(keys: "⇧⇥", what: "Cycle the permission mode inside a running session"),
                Row(keys: "⌥⌘N", what: "Jump to the next agent that needs you")
            ]),
            Section(title: "Canvas", rows: [
                Row(keys: "drag · scroll", what: "Pan"),
                Row(keys: "⌘-scroll · pinch", what: "Zoom"),
                Row(keys: "⌘0 · ⌘1", what: "Fit to content · actual size"),
                Row(keys: "double-click", what: "Centre a node"),
                Row(keys: "drag the header", what: "Move a node; the corner grip resizes it")
            ]),
            Section(title: "Terminals", rows: [
                Row(keys: "rest the pointer", what: "Hands the terminal the scroll wheel"),
                Row(keys: "click", what: "Type into it"),
                Row(keys: "⌘C", what: "Copy the selection")
            ]),
            Section(title: "Panels", rows: [
                Row(keys: "⌥⌘S · ⌥⌘I", what: "Sidebar · inspector"),
                Row(keys: "drag the inner edge", what: "Resize a panel")
            ])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(Theme.ui(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { store.shortcutsOpen = false } label: {
                    Image(systemName: "xmark").font(Theme.ui(10, .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().overlay(Theme.hairline)

            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(Theme.ui(9, .heavy))
                                .tracking(0.8)
                                .foregroundStyle(Theme.textTertiary)
                            ForEach(section.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(row.keys)
                                        .font(Theme.mono(10.5, .medium))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 128, alignment: .leading)
                                    Text(row.what)
                                        .font(Theme.ui(11.5))
                                        .foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 520)
        .background(Theme.surfaceSunken)
    }
}
