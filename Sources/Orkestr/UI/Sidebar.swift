import SwiftUI

/// Left rail: every workspace, with its repositories nested underneath.
///
/// Workspaces are the organising unit, so they are all listed here — not just
/// the open one. Clicking a repository pans the canvas to its card; clicking a
/// different workspace switches the board.
struct Sidebar: View {
    @Bindable var store: OrkestrStore
    @Binding var sheet: OrkestrSheet?
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    runningSection
                    SectionHeader(
                        title: "Workspaces",
                        count: store.workspaces.count,
                        tint: Theme.textTertiary,
                        trailing: store.isLoadingGit ? "scanning…" : nil,
                        action: ("plus", "New workspace", { sheet = .newWorkspace })
                    )
                    ForEach(store.workspaces) { workspace in
                        workspaceSection(workspace)
                    }
                    if store.workspaces.isEmpty {
                        Text("No workspaces yet.")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                    }
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
                .foregroundStyle(Theme.textTertiary)
            TextField("Search sessions, paths, branches", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { store.focusMatches() }
            if store.isSearching {
                Text("\(store.matchingNodes.count)")
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(Theme.accent)
                Button { store.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var runningSection: some View {
        let running = store.activeWorkspace?.terminals.filter { store.terminals.isRunning($0.id) } ?? []
        if !running.isEmpty {
            SectionHeader(title: "Running", count: running.count, tint: Theme.busy)
            ForEach(running) { terminal in
                SidebarRow(
                    isSelected: store.selection == .terminal(terminal.id),
                    action: { store.reveal(.terminal(terminal.id)) }
                ) {
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
                            Text(terminal.role.label)
                                .font(Theme.mono(9.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(Theme.clean).frame(width: 5, height: 5)
                    }
                }
            }
            Spacer().frame(height: 14)
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
                Button("Close (keep worktrees)") {
                    store.deleteWorkspace(workspace.id, removeWorktrees: false, force: false)
                }
                Button("Delete worktrees") {
                    store.deleteWorkspace(workspace.id, removeWorktrees: true, force: false)
                }
                Button("Delete and discard changes", role: .destructive) {
                    store.deleteWorkspace(workspace.id, removeWorktrees: true, force: true)
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
        let sessions = store.graph.edges.filter {
            $0.to == .worktree(repo.worktreePath) && $0.kind == .ranIn
        }
        return SidebarRow(
            isSelected: store.selection == .worktree(repo.worktreePath),
            action: { store.reveal(.worktree(repo.worktreePath)) }
        ) {
            HStack(spacing: 6) {
                Image(systemName: repo.isReady ? "square.on.square" : "exclamationmark.triangle.fill")
                    .font(Theme.ui(9))
                    .foregroundStyle(
                        !repo.isReady ? Theme.dirty
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
                        .foregroundStyle(repo.isReady ? Theme.textTertiary : Theme.dirty)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 16)
        }
        .contextMenu {
            Button("Open agent terminal here") { store.openTerminal(role: .repo, repoID: repo.id) }
            Button("Open shell here") { store.openTerminal(role: .shell, repoID: repo.id) }
            Divider()
            Button("Open in editor") { store.openInEditor(repo.worktreePath) }
            Button("Reveal in Finder") { store.revealInFinder(repo.worktreePath) }
            Divider()
            Button("Remove from workspace") { store.removeRepo(repo.id) }
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
                        .fill(isSelected ? Theme.accent.opacity(0.16) : (hovering ? SwiftUI.Color.white.opacity(0.05) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
