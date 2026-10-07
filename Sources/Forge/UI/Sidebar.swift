import SwiftUI

/// Left rail: what is running right now, the linkedWorktrees in this workspace, and the
/// repositories behind them. Selecting a row pans the canvas to that card rather
/// than replacing the view, so the board stays the primary surface.
struct Sidebar: View {
    @Bindable var store: ForgeStore
    @Binding var sheet: ForgeSheet?
    @State private var collapsed: Set<String> = []

    private var liveRows: [(LiveSession, SessionSummary?)] {
        store.live.values
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return lhs.status == .busy }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            .map { live in
                let summary = store.graph.nodes.compactMap { node -> SessionSummary? in
                    guard case .session(let summary, _, _) = node.kind, summary.id == live.sessionId else { return nil }
                    return summary
                }.first
                return (live, summary)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    if !liveRows.isEmpty {
                        SectionHeader(title: "Live now", count: liveRows.count, tint: Theme.busy)
                        ForEach(liveRows, id: \.0.pid) { live, summary in
                            liveRow(live, summary)
                        }
                        Spacer().frame(height: 14)
                    }

                    SectionHeader(
                        title: "Linked worktrees",
                        count: store.activeWorkspace?.linkedWorktrees.count ?? 0,
                        tint: Theme.accent,
                        action: ("plus", "New link", { sheet = .newLink })
                    )
                    ForEach(store.activeWorkspace?.linkedWorktrees.sorted { $0.createdAt > $1.createdAt } ?? []) { link in
                        linkSection(link)
                    }
                    if store.activeWorkspace?.linkedWorktrees.isEmpty == true {
                        hint("No linkedWorktrees yet. A link cuts one branch across every repo at once.")
                    }

                    Spacer().frame(height: 14)

                    SectionHeader(
                        title: "Repositories",
                        count: store.activeWorkspace?.repos.count ?? 0,
                        tint: Theme.textTertiary,
                        trailing: store.isLoadingGit ? "scanning…" : nil,
                        action: ("plus", "Add repositories", { sheet = .addRepos })
                    )
                    ForEach(store.activeWorkspace?.repos ?? []) { repo in
                        repoSection(repo)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 258)
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

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(10.5))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
    }

    // MARK: Rows

    private func liveRow(_ live: LiveSession, _ summary: SessionSummary?) -> some View {
        SidebarRow(
            isSelected: store.selection == .session(live.sessionId),
            action: { store.reveal(.session(live.sessionId)) }
        ) {
            HStack(spacing: 7) {
                StatusDot(status: live.status, zoom: Zoom(scale: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary?.displayTitle ?? live.name ?? String(live.sessionId.prefix(8)))
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(live.name ?? URL(fileURLWithPath: live.cwd ?? "—").lastPathComponent)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Text(live.status == .busy ? "working" : "idle")
                    .font(Theme.ui(9, .semibold))
                    .foregroundStyle(live.status == .busy ? Theme.busy : Theme.idle)
            }
        }
    }

    private func linkSection(_ link: LinkedWorktree) -> some View {
        let key = "link:" + link.id.uuidString
        let isCollapsed = collapsed.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                toggle(key)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.ui(8.5, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Image(systemName: "square.link.3d.up.fill")
                        .font(Theme.ui(9.5))
                        .foregroundStyle(Theme.repoTint(link.branch))
                    Text(link.name)
                        .font(Theme.ui(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(link.checkouts.filter(\.isReady).count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Launch agent here…") { sheet = .launchAgent(firstNode(of: link)) }
                Divider()
                Button("Remove link") { store.removeLink(link.id, force: false, deleteBranch: false) }
                Button("Remove link and discard changes") {
                    store.removeLink(link.id, force: true, deleteBranch: true)
                }
            }

            if !isCollapsed {
                ForEach(link.checkouts) { checkout in
                    memberRow(checkout, branch: link.branch)
                }
            }
        }
    }

    private func memberRow(_ checkout: LinkedCheckout, branch: String) -> some View {
        SidebarRow(
            isSelected: store.selection == .worktree(checkout.path),
            action: { store.reveal(.worktree(checkout.path)) }
        ) {
            HStack(spacing: 6) {
                Image(systemName: checkout.isReady ? "square.on.square" : "exclamationmark.triangle.fill")
                    .font(Theme.ui(9))
                    .foregroundStyle(checkout.isReady ? Theme.worktree : Theme.dirty)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(checkout.repoName)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(checkout.failure ?? branch)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(checkout.isReady ? Theme.branch.opacity(0.85) : Theme.dirty)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
        }
    }

    private func repoSection(_ repo: WorkspaceRepo) -> some View {
        let key = "repo:" + repo.id
        let isCollapsed = collapsed.contains(key)
        let worktrees = store.worktreesByRepo[repo.id] ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                toggle(key)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.ui(8.5, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Circle().fill(Theme.repoTint(repo.id)).frame(width: 7, height: 7)
                    Text(repo.name)
                        .font(Theme.ui(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(worktrees.count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open in editor") { store.openInEditor(repo.path) }
                Button("Reveal in Finder") { store.revealInFinder(repo.path) }
                Divider()
                Button("Remove from workspace") { store.removeRepo(repo.id) }
            }

            if !isCollapsed {
                ForEach(worktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
    }

    private func worktreeRow(_ worktree: Worktree) -> some View {
        let sessions = store.graph.edges.filter { $0.to == .worktree(worktree.path) }
        return SidebarRow(
            isSelected: store.selection == .worktree(worktree.path),
            action: { store.reveal(.worktree(worktree.path)) }
        ) {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "shippingbox.fill" : "square.on.square")
                    .font(Theme.ui(9))
                    .foregroundStyle(worktree.isDirty ? Theme.dirty : Theme.worktree)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(worktree.name)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(worktree.branchLabel)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.branch.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if sessions.contains(where: \.isLive) {
                    Circle().fill(Theme.busy).frame(width: 5, height: 5)
                }
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 16)
        }
    }

    private func firstNode(of link: LinkedWorktree) -> NodeID? {
        link.checkouts.first(where: \.isReady).map { NodeID.worktree($0.path) }
    }

    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}

private struct SectionHeader: View {
    var title: String
    var count: Int
    var tint: Color
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
                        .fill(isSelected ? Theme.accent.opacity(0.16) : (hovering ? Color.white.opacity(0.05) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
