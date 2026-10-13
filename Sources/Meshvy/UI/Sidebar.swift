import SwiftUI

/// Left rail: every workspace, with its repositories nested underneath.
///
/// Workspaces are the organising unit, so they are all listed here — not just
/// the open one. Clicking a repository pans the canvas to its card; clicking a
/// different workspace switches the board.
struct Sidebar: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?
    @State private var collapsed: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    runningSection
                    browsersSection
                    SectionHeader(
                        title: "Workspaces",
                        count: store.liveWorkspaces.count,
                        tint: Theme.textTertiary,
                        trailing: store.isLoadingGit ? "scanning…" : nil,
                        action: ("plus", "New workspace", { sheet = .newWorkspace })
                    )
                    ForEach(store.liveWorkspaces) { workspace in
                        workspaceSection(workspace)
                    }
                    if store.liveWorkspaces.isEmpty {
                        Text("No workspaces yet.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                    }
                    archivedSection
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
        }
        .frame(width: store.sidebarWidth)
        .background(Theme.chrome)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.ui(11, .medium))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.textTertiary)
            SnapshotSafeField(
                placeholder: "Search sessions, paths, branches",
                text: $store.searchQuery
            )
            .focused($searchFocused)
            .onSubmit { store.focusMatches() }
            // Esc hands the board back: the filter goes, and the cursor with it.
            .onKeyPress(.escape) {
                store.searchQuery = ""
                searchFocused = false
                return .handled
            }
            if store.isSearching {
                Button { store.focusMatches() } label: {
                    Text("\(store.matchingNodes.count)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(store.matchingNodes.isEmpty ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Frame the matches on the board (⏎)")
                Button { store.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search (esc)")
            } else if !searchFocused {
                Text("⌘F")
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fill))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .onAppear(perform: takeFocusIfAsked)
        .onChange(of: store.searchFocusRequested) { _, asked in
            if asked { takeFocusIfAsked() }
        }
    }

    /// ⌘F used to show the sidebar and stop there, so with the sidebar already
    /// open it did nothing you could see, and the field still had to be
    /// clicked before anything could be typed into it.
    private func takeFocusIfAsked() {
        guard store.searchFocusRequested else { return }
        store.searchFocusRequested = false
        // A field only now being laid out cannot take focus in the same pass
        // that creates it.
        DispatchQueue.main.async { searchFocused = true }
    }

    /// Every live terminal, orchestrator included, ordered by how much it wants
    /// your attention. On a board of a dozen agents this is the list you read
    /// first — the canvas tells you where they are, this tells you who is stuck.
    @ViewBuilder
    private var runningSection: some View {
        let running = (store.activeWorkspace?.allTerminals ?? [])
            .filter { store.terminals.isRunning($0.id) }
            .sorted { lhs, rhs in
                let left = store.activity(for: lhs)?.state.precedence ?? -1
                let right = store.activity(for: rhs)?.state.precedence ?? -1
                return left == right ? lhs.createdAt < rhs.createdAt : left > right
            }
        if !running.isEmpty {
            SectionHeader(
                title: "Agents",
                count: running.count,
                tint: Theme.busy,
                trailing: store.agentsNeedingYou.isEmpty
                    ? nil : "\(store.agentsNeedingYou.count) waiting"
            )
            ForEach(running) { terminal in
                agentRow(terminal)
            }
            Spacer().frame(height: 14)
        }
    }

    private func agentRow(_ terminal: TerminalNode) -> some View {
        let id = store.canvasID(for: terminal)
        let activity = store.activity(for: terminal)
        let tint: Color = switch activity?.state {
        case .working: Theme.busy
        case .blocked: Theme.needsYou
        case .done: Theme.clean
        default: Theme.textTertiary
        }
        return SidebarRow(isSelected: store.selection == id, action: { store.reveal(id) }) {
            HStack(spacing: 7) {
                Image(systemName: terminal.role.icon)
                    .font(Theme.ui(9.5))
                    .foregroundStyle(terminal.role == .orchestrator ? Theme.accent : Theme.worktree)
                    .frame(width: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(terminal.title)
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(activity?.line ?? activity?.state.label ?? terminal.role.label)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if store.isUnread(terminal.id) {
                    UnreadDot(zoom: Zoom(scale: 1))
                } else {
                    Circle().fill(tint).frame(width: 5, height: 5)
                }
            }
        }
        // The same verbs the node itself offers, so stopping an agent does not
        // mean finding it on the board first.
        .contextMenu {
            Button("Restart") { store.restartTerminal(terminal.id) }
            Button("Reveal folder in Finder") { store.revealInFinder(terminal.cwd) }
            Button("Copy folder path") { store.copyToClipboard(terminal.cwd) }
            Divider()
            if terminal.role == .orchestrator {
                Button("Stop the orchestrator", role: .destructive) { store.requestStopOrchestrator() }
            } else {
                Button("Close terminal", role: .destructive) { store.requestClose(terminal.id) }
            }
        }
    }

    /// Browsers on the board, with whatever each page is throwing. The canvas
    /// shows you the page; this tells you which one has gone wrong while you
    /// were looking at something else.
    @ViewBuilder
    private var browsersSection: some View {
        let nodes = store.activeWorkspace?.browsers ?? []
        if !nodes.isEmpty {
            SectionHeader(
                title: "Browsers",
                count: nodes.count,
                tint: Theme.branch,
                action: ("plus", "New browser", { store.openBrowser() })
            )
            ForEach(nodes) { node in
                let problems = store.browsers.session(for: node.id)?
                    .console.filter { $0.level == .error }.count ?? 0
                SidebarRow(
                    isSelected: store.selection == .browser(node.id),
                    action: { store.reveal(.browser(node.id)) }
                ) {
                    HStack(spacing: 7) {
                        Image(systemName: "globe")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.branch)
                            .frame(width: 13)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(node.pageTitle ?? node.title)
                                .font(Theme.ui(11.5, .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(node.displayURL)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if problems > 0 {
                            Text("\(problems)")
                                .font(Theme.mono(9.5, .bold))
                                .foregroundStyle(Theme.danger)
                        }
                    }
                }
                .contextMenu {
                    Button("Reload") { store.reloadBrowser(node.id) }
                    Button("Open in default browser") { store.openInBrowser(node.url) }
                    Divider()
                    Button("Copy URL") { store.copyToClipboard(node.url) }
                    Button("Close browser", role: .destructive) { store.closeBrowser(node.id) }
                }
            }
            Spacer().frame(height: 14)
        }
    }

    /// Put away, not gone. Kept at the bottom and collapsed to one line each,
    /// so a long history of finished branches costs nothing to carry.
    @ViewBuilder
    private var archivedSection: some View {
        let archived = store.archivedWorkspaces
        if !archived.isEmpty {
            Spacer().frame(height: 14)
            SectionHeader(title: "Archived", count: archived.count, tint: Theme.textTertiary, trailing: nil)
            ForEach(archived) { workspace in
                SidebarRow(isSelected: false, action: { store.unarchiveWorkspace(workspace.id) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(Theme.ui(9))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workspace.name)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            Text(workspace.branch)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text(Format.relative(workspace.archivedAt ?? workspace.createdAt))
                            .font(Theme.ui(9))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .help("Restore “\(workspace.name)”")
                .contextMenu {
                    Button("Restore") { store.unarchiveWorkspace(workspace.id) }
                    Divider()
                    Button("Reveal folder in Finder") { store.revealInFinder(workspace.root) }
                    Divider()
                    Button("Delete worktrees…") {
                        store.requestDelete(workspace.id, removeWorktrees: true, force: false)
                    }
                    Button("Delete and discard changes…", role: .destructive) {
                        store.requestDelete(workspace.id, removeWorktrees: true, force: true)
                    }
                }
            }
        }
    }

    private func workspaceSection(_ workspace: Workspace) -> some View {
        let isActive = workspace.id == store.activeWorkspaceID
        let isCollapsed = collapsed.contains(workspace.id)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isActive {
                    if isCollapsed { collapsed.remove(workspace.id) } else { collapsed.insert(workspace.id) }
                } else {
                    store.activate(workspace.id)
                    collapsed.remove(workspace.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed || !isActive ? "chevron.right" : "chevron.down")
                        .font(Theme.ui(8.5, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Image(systemName: "rectangle.3.group.fill")
                        .font(Theme.ui(9.5))
                        .foregroundStyle(Theme.repoTint(workspace.branch))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(workspace.name)
                            .font(Theme.ui(12, .semibold))
                            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Text(workspace.branch)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.branch.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(workspace.repos.count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Theme.accent.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open orchestrator terminal") {
                    store.activate(workspace.id)
                    store.openTerminal(role: .orchestrator)
                }
                Button("Add repositories…") {
                    store.activate(workspace.id)
                    sheet = .addRepos
                }
                Divider()
                Button("Reveal folder in Finder") { store.revealInFinder(workspace.root) }
                Button("Copy branch name") { store.copyToClipboard(workspace.branch) }
                Divider()
                Button("Archive — keeps every worktree") { store.requestArchive(workspace.id) }
                Divider()
                Button("Close (keep worktrees)…") {
                    store.requestDelete(workspace.id, removeWorktrees: false, force: false)
                }
                Button("Delete worktrees…") {
                    store.requestDelete(workspace.id, removeWorktrees: true, force: false)
                }
                Button("Delete and discard changes…", role: .destructive) {
                    store.requestDelete(workspace.id, removeWorktrees: true, force: true)
                }
            }

            if isActive && !isCollapsed {
                ForEach(workspace.repos) { repo in
                    repoRow(repo, workspace: workspace)
                }
            }
        }
    }

    private func repoRow(_ repo: WorkspaceRepo, workspace: Workspace) -> some View {
        let worktree = store.worktrees[repo.worktreePath]
        // Past sessions and the agents working in it now — what the card on
        // the board counts, so the two never disagree.
        let sessions = store.graph.edges.filter {
            $0.to == .worktree(repo.worktreePath) && $0.kind == .ranIn
        }.count + workspace.terminals.filter { $0.repoID == repo.id && $0.sessionID != nil }.count
        return SidebarRow(
            isSelected: store.selection == .worktree(repo.worktreePath),
            action: { store.reveal(.worktree(repo.worktreePath)) }
        ) {
            HStack(spacing: 6) {
                Image(systemName: repo.isReady ? "square.on.square" : "exclamationmark.triangle.fill")
                    .font(Theme.ui(9))
                    .foregroundStyle(
                        !repo.isReady ? Theme.danger
                            : (worktree?.isDirty == true ? Theme.dirty : Theme.worktree)
                    )
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.name)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(repo.failure ?? (worktree.map(describe) ?? "checking…"))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(repo.isReady ? Theme.textTertiary : Theme.danger)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if sessions > 0 {
                    Text("\(sessions)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .help("\(sessions) \(sessions == 1 ? "session" : "sessions") in this repository")
                }
            }
            .padding(.leading, 16)
        }
        .contextMenu {
            Button("Open agent terminal here") { store.openTerminal(role: .repo, repoID: repo.id) }
            Button("Open shell here") { store.openTerminal(role: .shell, repoID: repo.id) }
            Button("Open a browser here") { store.openBrowser(repoID: repo.id) }
            Divider()
            Button("Open in editor") { store.openInEditor(repo.worktreePath) }
            Button("Reveal in Finder") { store.revealInFinder(repo.worktreePath) }
            Divider()
            Button("Remove from workspace") { store.requestRemoveRepo(repo.id) }
        }
    }

    private func describe(_ worktree: Worktree) -> String {
        guard worktree.hasStatus else { return "checking…" }
        let dirty = (worktree.dirtyFiles ?? 0) + (worktree.untrackedFiles ?? 0)
        return dirty == 0 ? "clean" : "\(dirty) changed"
    }
}

private struct SectionHeader: View {
    var title: String
    var count: Int
    var tint: SwiftUI.Color
    var trailing: String?
    var action: (icon: String, help: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(Theme.ui(9.5, .heavy))
                .tracking(0.7)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(Theme.mono(9.5, .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(Theme.ui(9.5)).foregroundStyle(Theme.textTertiary)
            }
            if let action {
                Button(action: action.run) {
                    Image(systemName: action.icon)
                        .font(Theme.ui(9.5, .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(action.help)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

private struct SidebarRow<Content: View>: View {
    var isSelected: Bool
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.16) : (hovering ? Theme.fill : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
