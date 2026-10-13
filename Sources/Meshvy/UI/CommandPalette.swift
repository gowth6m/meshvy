import AppKit
import SwiftUI

/// One row of the palette.
struct PaletteItem: Identifiable {
    enum Group: Int, Comparable {
        case needsYou = 0
        case action = 1
        case node = 2
        case output = 3

        var title: String {
            switch self {
            case .needsYou: return "Waiting for you"
            case .action: return "Actions"
            case .node: return "Go to"
            case .output: return "Found in terminal output"
            }
        }

        static func < (lhs: Group, rhs: Group) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var group: Group
    var title: String
    var subtitle: String?
    var icon: String
    var tint: Color = Theme.textSecondary
    /// Extra words the query may match that are not shown.
    var keywords: String = ""
    var run: () -> Void
}

/// ⌘K. One box for everything: start an agent, jump to a node, or find the
/// terminal that printed the error you half-remember.
///
/// A board with a dozen terminals on it is faster to drive by name than by
/// panning, and the output search is the part that has no other home — the
/// canvas can show you where a node is but not what is on its screen.
struct CommandPalette: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        let items = PaletteCommands.all(store: store, sheet: $sheet)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Nothing typed: lead with anything stuck, then the actions.
            return items.filter { $0.group <= .action }
        }
        let needle = trimmed.lowercased()
        let matched = items.compactMap { item -> (PaletteItem, Int)? in
            let haystack = (item.title + " " + (item.subtitle ?? "") + " " + item.keywords).lowercased()
            guard let score = PaletteCommands.score(haystack, query: needle) else { return nil }
            return (item, score)
        }
        return (matched + PaletteCommands.outputMatches(store: store, query: needle).map { ($0, 500) })
            .sorted {
                $0.0.group == $1.0.group ? $0.1 < $1.1 : $0.0.group < $1.0.group
            }
            .map(\.0)
            .prefix(40)
            .map { $0 }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Clicking away is the same as pressing Escape.
            Color.black.opacity(0.35)
                .onTapGesture { close() }

            // Built once per render: the output search reads every live
            // terminal's screen, which is not something to do four times for
            // one keystroke.
            let items = results
            VStack(spacing: 0) {
                field
                if items.isEmpty {
                    Text("Nothing matches")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else {
                    Divider().overlay(Theme.hairline)
                    list(items)
                }
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(13, .medium))
                .foregroundStyle(Theme.textTertiary)
            // A snapshot cannot draw an AppKit text field; the live app always
            // gets the real one.
            if isSnapshot {
                Text(query.isEmpty ? "Start an agent, go to a node, search output…" : query)
                    .font(Theme.ui(14))
                    .foregroundStyle(query.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
            TextField("Start an agent, go to a node, search output…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit(activate)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) { close(); return .handled }
            }
            Text("esc")
                .font(Theme.mono(9.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fill))
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func list(_ items: [PaletteItem]) -> some View {
        ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index == 0 || items[index - 1].group != item.group {
                        Text(item.group.title.uppercased())
                            .font(Theme.ui(9, .heavy))
                            .tracking(0.7)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, index == 0 ? 10 : 12)
                            .padding(.bottom, 4)
                    }
                    row(item, isHighlighted: index == highlighted)
                        .onTapGesture { item.run(); close() }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: 420)
    }

    private func row(_ item: PaletteItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(Theme.ui(11.5, .medium))
                .foregroundStyle(item.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.ui(12.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if isHighlighted {
                Text("↵").font(Theme.mono(10, .bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Theme.accent.opacity(0.16) : .clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let count = results.count
        guard count > 0 else { return .handled }
        highlighted = (highlighted + delta + count) % count
        return .handled
    }

    private func activate() {
        let items = results
        guard highlighted < items.count else { return }
        items[highlighted].run()
        close()
    }

    private func close() {
        query = ""
        highlighted = 0
        store.paletteOpen = false
    }
}

/// Everything the palette can do. Kept out of the view so the list is readable
/// as a list.
@MainActor
enum PaletteCommands {
    static func all(store: MeshvyStore, sheet: Binding<MeshvySheet?>) -> [PaletteItem] {
        var items: [PaletteItem] = []

        // Anything stuck comes first, always, typed or not.
        for node in store.agentsNeedingYou {
            let id = store.canvasID(for: node)
            items.append(PaletteItem(
                id: "needs:" + node.id.uuidString,
                group: .needsYou,
                title: node.title,
                subtitle: store.activity(for: node)?.message ?? "Waiting for you",
                icon: "hand.raised.fill",
                tint: Theme.needsYou,
                keywords: "needs you blocked permission"
            ) { store.reveal(id) })
        }

        items += actions(store: store, sheet: sheet)

        for node in store.graph.nodes {
            guard let described = describe(node) else { continue }
            items.append(PaletteItem(
                id: "node:" + node.id.storageKey,
                group: .node,
                title: described.title,
                subtitle: described.subtitle,
                icon: described.icon,
                tint: described.tint,
                keywords: node.searchText
            ) { store.reveal(node.id) })
        }
        return items
    }

    private static func actions(store: MeshvyStore, sheet: Binding<MeshvySheet?>) -> [PaletteItem] {
        func item(
            _ id: String, _ title: String, _ icon: String,
            subtitle: String? = nil, keywords: String = "", tint: Color = Theme.textSecondary,
            run: @escaping () -> Void
        ) -> PaletteItem {
            PaletteItem(
                id: id, group: .action, title: title, subtitle: subtitle,
                icon: icon, tint: tint, keywords: keywords, run: run
            )
        }

        var items: [PaletteItem] = []

        if store.hasWorkspace {
            items.append(item(
                "act:orchestrator",
                store.isOrchestratorRunning ? "Go to orchestrator" : "Start orchestrator",
                "point.3.connected.trianglepath.dotted",
                subtitle: store.activeWorkspace?.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                keywords: "claude code agent start run",
                tint: Theme.accent
            ) {
                if store.isOrchestratorRunning, let id = store.activeWorkspace?.id {
                    store.reveal(.workspace(id))
                } else {
                    store.startOrchestrator()
                }
            })

            for repo in store.activeWorkspace?.readyRepos ?? [] {
                items.append(item(
                    "act:agent:" + repo.id, "New agent in \(repo.name)", "hammer.fill",
                    subtitle: repo.worktreePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    keywords: "claude terminal agent repo " + repo.name,
                    tint: Theme.worktree
                ) { store.openTerminal(role: .repo, repoID: repo.id) })
                items.append(item(
                    "act:shell:" + repo.id, "New shell in \(repo.name)", "terminal.fill",
                    keywords: "bash zsh terminal " + repo.name
                ) { store.openTerminal(role: .shell, repoID: repo.id) })
            }

            items.append(item(
                "act:shell", "New shell at the workspace root", "terminal", keywords: "bash zsh ⌘t"
            ) { store.openTerminal(role: .shell) })
            items.append(item(
                "act:addRepos", "Add repositories…", "plus.rectangle.on.folder", keywords: "⇧⌘o open"
            ) { sheet.wrappedValue = .addRepos })
            items.append(item(
                "act:browser", "New browser on the board", "globe",
                subtitle: "Watch the running app, and let an agent drive it",
                keywords: "⌘b browser web page localhost chrome preview",
                tint: Theme.branch
            ) { store.openBrowser() })
            if let active = store.activeWorkspace {
                items.append(item(
                    "act:archive", "Archive “\(active.name)”", "archivebox",
                    subtitle: "Out of the way, worktrees untouched",
                    keywords: "⌥⌘a archive put away hide done"
                ) { store.archiveWorkspace(active.id) })
            }
        }

        items.append(item(
            "act:newWorkspace", "New workspace…", "rectangle.3.group", keywords: "⇧⌘n create"
        ) { sheet.wrappedValue = .newWorkspace })

        for workspace in store.liveWorkspaces where workspace.id != store.activeWorkspaceID {
            items.append(item(
                "act:switch:" + workspace.id.uuidString,
                "Switch to “\(workspace.name)”", "arrow.left.arrow.right",
                subtitle: workspace.branch, keywords: "workspace open " + workspace.name
            ) { store.activate(workspace.id) })
        }

        for workspace in store.archivedWorkspaces {
            items.append(item(
                "act:restore:" + workspace.id.uuidString,
                "Restore “\(workspace.name)”", "tray.and.arrow.up",
                subtitle: "Archived " + Format.relative(workspace.archivedAt ?? workspace.createdAt),
                keywords: "archived restore unarchive " + workspace.name
            ) { store.unarchiveWorkspace(workspace.id) })
        }

        for mode in PermissionMode.allCases where mode != store.permissionMode {
            items.append(item(
                "act:mode:" + mode.rawValue, "Permission mode: \(mode.label)", mode.icon,
                subtitle: mode.detail, keywords: "permission mode " + mode.rawValue,
                tint: mode.isRisky ? Theme.dirty : Theme.textSecondary
            ) { store.selectPermissionMode(mode) })
        }

        for effort in AgentEffort.allCases where effort != store.agentEffort {
            items.append(item(
                "act:effort:" + effort.rawValue, "Effort: \(effort.label)", effort.icon,
                subtitle: effort.detail, keywords: "effort thinking reasoning " + effort.rawValue
            ) { store.selectEffort(effort) })
        }

        items.append(item(
            "act:notify",
            store.notifier.isEnabled ? "Turn off agent notifications" : "Notify me when an agent needs me",
            "bell", keywords: "notification alert badge"
        ) { store.notifier.isEnabled.toggle(); store.persistLayout() })

        items.append(item("act:refresh", "Refresh everything", "arrow.clockwise", keywords: "⌘r reload") {
            store.refreshAll()
        })
        items.append(item("act:fit", "Fit to content", "arrow.up.left.and.arrow.down.right", keywords: "⌘0 zoom") {
            store.fit()
        })
        items.append(item("act:actual", "Actual size", "1.magnifyingglass", keywords: "⌘1 zoom 100%") {
            store.zoomToActualSize()
        })
        items.append(item("act:reset", "Reset auto-layout", "square.grid.2x2", keywords: "tidy arrange") {
            store.resetLayout()
        })
        items.append(item("act:shortcuts", "Keyboard shortcuts", "keyboard", keywords: "⌘/ help keys") {
            store.shortcutsOpen = true
        })
        return items
    }

    private struct Described {
        var title: String
        var subtitle: String?
        var icon: String
        var tint: Color
    }

    private static func describe(_ node: CanvasNode) -> Described? {
        switch node.kind {
        case .workspace(let workspace):
            return Described(
                title: workspace.name, subtitle: workspace.branch,
                icon: "rectangle.3.group.fill", tint: Theme.accent
            )
        case .terminal(let terminal):
            return Described(
                title: terminal.title,
                subtitle: terminal.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                icon: terminal.role.icon, tint: Theme.worktree
            )
        case .session(let summary, _, _):
            return Described(
                title: summary.displayTitle, subtitle: summary.workspaceName,
                icon: "clock.arrow.circlepath", tint: Theme.textTertiary
            )
        case .subAgent(let agent):
            return Described(
                title: agent.title, subtitle: agent.kind,
                icon: "person.2.fill", tint: Theme.sidechain
            )
        case .browser(let browser):
            return Described(
                title: browser.pageTitle ?? browser.title, subtitle: browser.displayURL,
                icon: "globe", tint: Theme.branch
            )
        }
    }

    // MARK: - Searching terminal output

    /// Matches the query against what each live terminal has on screen. This is
    /// the one thing the canvas cannot show you: which of a dozen terminals
    /// printed the thing you are looking for.
    static func outputMatches(store: MeshvyStore, query: String) -> [PaletteItem] {
        guard query.count >= 3, let workspace = store.activeWorkspace else { return [] }
        return workspace.allTerminals.compactMap { node in
            guard let session = store.terminals.session(for: node.id) else { return nil }
            let screen = session.screenText.lowercased()
            guard let hit = screen.range(of: query) else { return nil }
            let id = store.canvasID(for: node)
            return PaletteItem(
                id: "out:" + node.id.uuidString,
                group: .output,
                title: node.title,
                subtitle: excerpt(screen, around: hit),
                icon: "text.magnifyingglass",
                tint: Theme.busy
            ) { store.reveal(id) }
        }
    }

    /// The matching line, trimmed, so you can tell the hits apart.
    private static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let start = text[text.startIndex..<range.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let end = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return text[start..<end].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Matching

    /// Substring first, then a loose in-order character match so `nwrk` still
    /// finds "New worktree". Lower is better; nil means no match.
    static func score(_ haystack: String, query: String) -> Int? {
        if let found = haystack.range(of: query) {
            return haystack.distance(from: haystack.startIndex, to: found.lowerBound)
        }
        var cursor = haystack.startIndex
        var gaps = 0
        for character in query {
            guard let next = haystack[cursor...].firstIndex(of: character) else { return nil }
            gaps += haystack.distance(from: cursor, to: next)
            cursor = haystack.index(after: next)
        }
        return 200 + gaps
    }
}
