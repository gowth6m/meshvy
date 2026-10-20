import AppState
import DesignSystem
import SwiftUI

/// ⌘/ — the keys and the gestures, in one place.
///
/// Most of the board teaches itself now — the tools are on a palette, the
/// handles appear under the pointer — so what is left here is the half that
/// cannot be seen: the keys, and the rules about which node owns the wheel and
/// the keyboard.
public struct ShortcutsSheet: View {
    @Bindable public var store: MeshvyStore

    private struct Row: Identifiable {
        public var keys: String
        public var what: String
        public var id: String { keys + what }
    }

    private struct Section: Identifiable {
        public var title: String
        public var rows: [Row]
        public var id: String { title }
    }

    private var sections: [Section] {
        [
            Section(title: "The board", rows: [
                Row(keys: "V · H", what: "Select · hand. Esc always comes back to Select"),
                Row(keys: "A · S · B", what: "Draw a new agent · shell · browser, then drag out its size"),
                Row(keys: "drag empty space", what: "Draw a box around nodes to select them; ⇧ adds to the selection"),
                Row(keys: "space · scroll", what: "Pan. ⌘-scroll or pinch to zoom"),
                Row(keys: "⌘0 · ⌘1", what: "Fit to content · actual size"),
                Row(keys: "⌘A", what: "Select everything on the board")
            ]),
            Section(title: "A node", rows: [
                Row(keys: "drag its header or edge", what: "Move it. Everything inside stays the node's own"),
                Row(keys: "drag a handle", what: "Resize it — eight of them, on anything that is selected"),
                Row(keys: "hover an edge", what: "A pink + appears on each side; drag one onto another node to link them"),
                Row(keys: "⌘ while dragging", what: "Ignore the alignment guides"),
                Row(keys: "arrows · ⇧arrows", what: "Nudge by one · ten"),
                Row(keys: "⌘⌫", what: "Close what is selected. Never plain ⌫ — that belongs to whatever you are typing in"),
                Row(keys: "right-click", what: "Everything else a node can do — restart, reveal, copy, unlink, close"),
                Row(keys: "double-click a card", what: "Centre it")
            ]),
            Section(title: "Agents", rows: [
                Row(keys: "⇧⌘T", what: "Start or focus the orchestrator"),
                Row(keys: "⌘T", what: "New shell"),
                Row(keys: "⇧⇥", what: "Cycle the permission mode inside a running session"),
                Row(keys: "⌥⌘N", what: "Jump to the next agent that needs you"),
                Row(keys: "the pill on a card", what: "Model, effort and permission mode — remembered for the next one")
            ]),
            Section(title: "Terminals and browsers", rows: [
                Row(keys: "click into one", what: "Type into it. It keeps the keyboard until you click elsewhere"),
                Row(keys: "scroll inside it", what: "Its own scrollback or page — the board pans everywhere else"),
                Row(keys: "⏎ in the address bar", what: "Go — a bare localhost:3000 is enough"),
                Row(keys: "browser_* tools", what: "What an agent drives a browser with; the id is in its header")
            ]),
            Section(title: "Finding things", rows: [
                Row(keys: "⌘K", what: "Command palette — agents, nodes, terminal output"),
                Row(keys: "⌘F", what: "Find on the board; ⇧⌘F frames the hits"),
                Row(keys: "esc in the search", what: "Clear it and hand the board back"),
                Row(keys: "⌘R", what: "Refresh everything; ⇧⌘R git only")
            ]),
            Section(title: "Workspaces and panels", rows: [
                Row(keys: "⇧⌘N · ⇧⌘O", what: "New workspace · add repositories"),
                Row(keys: "⌥⌘A", what: "Archive the workspace — keeps every worktree"),
                Row(keys: "⌥⌘S · ⌥⌘I", what: "Sidebar · inspector"),
                Row(keys: "drag the inner edge", what: "Resize a panel"),
                Row(keys: "⌘/", what: "This list")
            ])
        ]
    }

    public var body: some View {
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
                                    // Wide enough for the longest gesture —
                                    // "⏎ in the address bar" was cut short.
                                    Text(row.keys)
                                        .font(Theme.mono(10.5, .medium))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 156, alignment: .leading)
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
