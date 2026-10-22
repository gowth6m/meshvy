import AgentsUI
import AppState
import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI

/// Left rail: the open workspace's coordinator and threads, then every
/// workspace with its repositories nested underneath.
///
/// The top half reads like a project in Claude Code. The coordinator is the
/// one main chat, where you ask for things; each piece of work it hands out is
/// a thread, listed under it with where it stands, whatever needs you first.
/// Finished threads are resolved out of the way.
///
/// Workspaces are the organising unit, so they are all listed below — not just
/// the open one. Clicking a repository puts its changes in the inspector and
/// pans to the workspace node its chip sits on; clicking a different workspace
/// switches the board.
public struct Sidebar: View {
    @Bindable public var store: MeshvyStore
    @Binding public var sheet: MeshvySheet?
    @State private var collapsed: Set<UUID> = []
    @State private var showResolved = false
    @FocusState private var searchFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    coordinatorSection
                    threadsSection
                    shellsSection
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

    // MARK: - Coordinator and threads

    /// The workspace's main chat. Always the first row, running or not, so
    /// where to ask for something is never in question.
    @ViewBuilder
    private var coordinatorSection: some View {
        if let workspace = store.activeWorkspace {
            let node = workspace.orchestrator
            let isRunning = store.isCoordinatorRunning
            let activity: AgentActivity? = node.flatMap { store.activity(for: $0) }
            let id = NodeID.workspace(workspace.id)
            let subtitle: String = isRunning
                ? (activity?.line ?? "Ask for something; it starts the threads")
                : "Not running — click to start"
            SectionHeader(title: "Coordinator", count: nil, tint: Theme.accent)
            SidebarRow(
                isSelected: store.selection == id,
                action: { isRunning ? store.reveal(id) : store.startCoordinator() }
            ) {
                HStack(spacing: 7) {
                    Image(systemName: TerminalNode.Role.orchestrator.icon)
                        .font(Theme.ui(10))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Main chat")
                            .font(Theme.ui(11.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(Theme.ui(9.5))
                            .foregroundStyle(activity?.state == .blocked ? Theme.needsYou : Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if let node, store.isUnread(node.id) {
                        UnreadDot(zoom: Zoom(scale: 1))
                    } else if !isRunning {
                        Image(systemName: "play.fill")
                            .font(Theme.ui(8.5, .bold))
                            .foregroundStyle(Theme.accent)
                    } else if let state = activity?.state, state.badge != nil {
                        AgentBadge(state: state, zoom: Zoom(scale: 1))
                    }
                }
            }
            .help(isRunning
                ? "The coordinator: tell it what you want, and it starts a thread for each piece of work"
                : "Start the coordinator (⇧⌘T)")
            .contextMenu {
                if isRunning, let node {
                    Button("Restart") { store.restartTerminal(node.id) }
                    Divider()
                    Button("Stop the coordinator", role: .destructive) { store.requestStopCoordinator() }
                } else {
                    Button("Start the coordinator") { store.startCoordinator() }
                }
            }
            Spacer().frame(height: 14)
        }
    }

    /// One row per piece of work, whatever wants you first. Resolved threads
    /// fold into one line at the bottom.
    @ViewBuilder
    private var threadsSection: some View {
        if store.hasWorkspace {
            let open = store.openThreads
            let resolved = store.resolvedThreads
            let waiting: Int = open.filter { store.threadState(for: $0) == .needsYou }.count
            SectionHeader(
                title: "Threads",
                count: open.count,
                tint: Theme.worktree,
                trailing: waiting == 0 ? nil : "\(waiting) need\(waiting == 1 ? "s" : "") you",
                action: ("plus", "New thread you drive yourself", { store.newThread() })
            )
            ForEach(open) { thread in
                threadRow(thread)
            }
            if open.isEmpty {
                Text(store.isCoordinatorRunning
                    ? "Ask the coordinator for something and its threads appear here."
                    : "Start the coordinator, then ask it for something. Each piece of work becomes a thread here.")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            if !resolved.isEmpty {
                Button {
                    showResolved.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showResolved ? "chevron.down" : "chevron.right")
                            .font(Theme.ui(8, .bold))
                            .frame(width: 10)
                        Text("Resolved")
                            .font(Theme.ui(10.5, .medium))
                        Text("\(resolved.count)")
                            .font(Theme.mono(9.5, .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showResolved {
                    ForEach(resolved) { thread in
                        threadRow(thread)
                    }
                }
            }
            Spacer().frame(height: 14)
        }
    }

    private func threadRow(_ thread: TerminalNode) -> some View {
        let id = store.canvasID(for: thread)
        let state = store.threadState(for: thread)
        let activity = store.activity(for: thread)
        let repo: WorkspaceRepo? = store.activeWorkspace?.repos.first { $0.id == thread.repoID }
        let place: String = activity?.line ?? repo?.name ?? "workspace"
        return SidebarRow(isSelected: store.selection == id, action: { store.reveal(id) }) {
            HStack(alignment: .top, spacing: 7) {
                Group {
                    if store.isUnread(thread.id) {
                        UnreadDot(zoom: Zoom(scale: 1))
                    } else {
                        Image(systemName: state.icon)
                            .font(Theme.ui(9.5))
                            .foregroundStyle(ThreadStatePill.tint(state))
                    }
                }
                .frame(width: 13, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.title)
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(thread.isResolved ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(state.label)
                            .foregroundStyle(ThreadStatePill.tint(state))
                        Text("·")
                        Text(place)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .help(thread.openingTask ?? thread.title)
        // The same verbs the node itself offers, so dealing with a thread does
        // not mean finding it on the board first.
        .contextMenu {
            if thread.isResolved {
                Button("Reopen") { store.reopenThread(thread.id) }
            } else {
                Button("Resolve") { store.resolveThread(thread.id) }
            }
            Button("Restart") { store.restartTerminal(thread.id) }
            Divider()
            if let bridgeID = thread.bridgeID {
                Button("Copy thread id") { store.copyToClipboard(bridgeID) }
            }
            Button("Reveal folder in Finder") { store.revealInFinder(thread.cwd) }
            Divider()
            Button("Close thread", role: .destructive) { store.requestClose(thread.id) }
        }
    }

    /// Plain shells are not threads — nobody reports from them — so they get
    /// their own short list, and only while one is open.
    @ViewBuilder
    private var shellsSection: some View {
        let shells = store.shells
        if !shells.isEmpty {
            SectionHeader(title: "Shells", count: shells.count, tint: Theme.textTertiary)
            ForEach(shells) { shell in
                SidebarRow(
                    isSelected: store.selection == .terminal(shell.id),
                    action: { store.reveal(.terminal(shell.id)) }
                ) {
                    HStack(spacing: 7) {
                        Image(systemName: shell.role.icon)
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 13)
                        Text(shell.title)
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !store.terminals.isRunning(shell.id) {
                            Text("exited").font(Theme.ui(9.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                .contextMenu {
                    Button("Restart") { store.restartTerminal(shell.id) }
                    Button("Reveal folder in Finder") { store.revealInFinder(shell.cwd) }
                    Divider()
                    Button("Close shell", role: .destructive) { store.requestClose(shell.id) }
                }
            }
            Spacer().frame(height: 14)
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
                Button("Open the coordinator") {
                    store.activate(workspace.id)
                    store.startCoordinator()
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
        // Past sessions in it, and the agents working in it now: an agent's
        // session is drawn by its terminal rather than as a card of its own,
        // so counting the cards alone left out everything still running.
        let sessions = store.graph.nodes.filter { node in
            guard case .session = node.kind else { return false }
            return node.repoID == repo.id
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
            Button("New thread here") { store.newThread(repoID: repo.id) }
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
    public var title: String
    public var count: Int?
    public var tint: SwiftUI.Color
    public var trailing: String? = nil
    public var action: (icon: String, help: String, run: () -> Void)? = nil

    public var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(Theme.ui(9.5, .heavy))
                .tracking(0.7)
                .foregroundStyle(tint)
            if let count {
                Text("\(count)")
                    .font(Theme.mono(9.5, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
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
    public var isSelected: Bool
    public var action: () -> Void
    @ViewBuilder public var content: Content
    @State private var hovering = false

    public var body: some View {
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
