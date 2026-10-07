import SwiftUI

/// Left rail: what is running right now, and the repository tree. Selecting a
/// row pans the canvas to that node rather than replacing the view, so the board
/// stays the primary surface.
struct Sidebar: View {
    @Bindable var store: ForgeStore
    @State private var collapsedRepos: Set<String> = []

    private var liveSessions: [(LiveSession, SessionSummary?)] {
        store.live.values
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return lhs.status == .busy }
                return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
            }
            .map { live in (live, store.graph.nodes.compactMap { node -> SessionSummary? in
                guard case .session(let summary, _, _) = node.kind, summary.id == live.sessionId else { return nil }
                return summary
            }.first) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Theme.hairline)
            ScrollableStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    if !liveSessions.isEmpty {
                        SectionHeader(title: "Live now", count: liveSessions.count, tint: Theme.busy)
                        ForEach(liveSessions, id: \.0.pid) { live, summary in
                            liveRow(live, summary)
                        }
                        Spacer().frame(height: 14)
                    }

                    SectionHeader(
                        title: "Repositories",
                        count: store.boardRepos.count,
                        tint: Theme.textTertiary,
                        trailing: store.isLoadingGit ? "scanning…" : nil
                    )
                    ForEach(store.boardRepos) { repo in
                        repoSection(repo)
                    }

                    if store.boardRepos.isEmpty && !store.isLoadingGit {
                        Text("No git repositories found in your session history.")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
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
                Button {
                    store.searchQuery = ""
                } label: {
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

    // MARK: Rows

    private func liveRow(_ live: LiveSession, _ summary: SessionSummary?) -> some View {
        SidebarRow(
            isSelected: store.selection == .session(live.sessionId),
            action: { store.reveal(.session(live.sessionId)) }
        ) {
            HStack(spacing: 7) {
                StatusDot(status: live.status, zoom: Zoom(scale: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary?.displayTitle ?? live.name ?? live.sessionId.prefix(8).description)
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(workspaceLabel(live))
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

    private func workspaceLabel(_ live: LiveSession) -> String {
        if let name = live.name, !name.isEmpty { return name }
        guard let cwd = live.cwd else { return "—" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func repoSection(_ repo: Repo) -> some View {
        let isCollapsed = collapsedRepos.contains(repo.id)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isCollapsed { collapsedRepos.remove(repo.id) } else { collapsedRepos.insert(repo.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(Theme.ui(8.5, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Circle()
                        .fill(Theme.repoTint(repo.id))
                        .frame(width: 7, height: 7)
                    Text(repo.name)
                        .font(Theme.ui(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(repo.worktrees.count)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(repo.worktrees) { worktree in
                    worktreeRow(worktree)
                }
            }
        }
    }

    private func worktreeRow(_ worktree: Worktree) -> some View {
        let sessionCount = store.graph.edges.filter { $0.to == .worktree(worktree.path) }.count
        let liveCount = store.graph.edges.filter { $0.to == .worktree(worktree.path) && $0.isLive }.count
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
                if liveCount > 0 {
                    Circle().fill(Theme.busy).frame(width: 5, height: 5)
                }
                if sessionCount > 0 {
                    Text("\(sessionCount)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.leading, 16)
        }
    }
}

private struct SectionHeader: View {
    var title: String
    var count: Int
    var tint: Color
    var trailing: String?

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
                Text(trailing)
                    .font(Theme.ui(9.5))
                    .foregroundStyle(Theme.textTertiary)
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
