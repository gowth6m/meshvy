import Combine
import SwiftUI

struct RootView: View {
    @Bindable var store: MeshvyStore
    @State private var sheet: MeshvySheet?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, sheet: $sheet)
            Divider().overlay(Theme.hairline)

            if store.hasWorkspace {
                HStack(spacing: 0) {
                    if store.sidebarVisible {
                        Sidebar(store: store, sheet: $sheet)
                        ResizeHandle(
                            edge: .leading,
                            width: $store.sidebarWidth,
                            range: 200...520,
                            onCommit: store.persistLayout
                        )
                    }
                    CanvasView(store: store, sheet: $sheet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.inspectorVisible {
                        ResizeHandle(
                            edge: .trailing,
                            width: $store.inspectorWidth,
                            range: 320...900,
                            onCommit: store.persistLayout
                        )
                        InspectorView(store: store, sheet: $sheet)
                    }
                }
            } else {
                EmptyStateView(store: store, sheet: $sheet)
            }

            Divider().overlay(Theme.hairline)
            StatusBar(store: store)
        }
        // The title bar is hidden, but SwiftUI still insets the window's content
        // below where it would have been — a 32pt strip above the top bar with
        // the traffic lights marooned in it. Taking the inset back lets the bar
        // run to the top of the window and hold the lights on its own centre line.
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        // System controls — text selection, spinners, menu checkmarks — follow
        // the palette rather than the user's macOS accent colour.
        .tint(Theme.accent)
        .overlay(alignment: .top) { BannerView(store: store) }
        // The palette and the shortcut list are overlays rather than sheets:
        // a second `.sheet` on the same view would fight the first one, and
        // both of these want to sit over the board, not replace it.
        .overlay {
            if store.paletteOpen { CommandPalette(store: store, sheet: $sheet) }
        }
        .overlay {
            if store.shortcutsOpen {
                ZStack {
                    Color.black.opacity(0.35)
                        .onTapGesture { store.shortcutsOpen = false }
                    ShortcutsSheet(store: store)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.hairlineStrong, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
                }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .newWorkspace: NewWorkspaceSheet(store: store)
            case .addRepos: AddReposSheet(store: store)
            case .update: UpdateSheet(store: store)
            }
        }
        // Every "are you sure?" in the app, asked from one place — see
        // `MeshvyStore.Confirmation`. Presented here rather than beside each
        // button, so a context menu that has already closed can still ask.
        .confirmationDialog(
            store.confirmation?.title ?? "",
            isPresented: Binding(
                get: { store.confirmation != nil },
                set: { if !$0 { store.confirmation = nil } }
            ),
            titleVisibility: .visible,
            presenting: store.confirmation
        ) { confirmation in
            Button(confirmation.action, role: .destructive) { confirmation.run() }
            if let alternative = confirmation.alternative {
                Button(alternative.label) { alternative.run() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .onAppear { store.bootstrap() }
        .onReceive(of: .meshvyPalette) { store.paletteOpen.toggle() }
        .onReceive(of: .meshvyShortcuts) { store.shortcutsOpen.toggle() }
        .onReceive(of: .meshvyNextAgent) { if store.hasWorkspace { store.revealNextNeedingYou() } }
        .onReceive(of: .meshvyToggleSidebar) { store.sidebarVisible.toggle() }
        .onReceive(of: .meshvyToggleInspector) { store.inspectorVisible.toggle() }
        .onReceive(of: .meshvyFocusSearch) {
            guard store.hasWorkspace else { return }
            store.sidebarVisible = true
            store.searchFocusRequested = true
        }
        .onReceive(of: .meshvyNewWorkspace) { sheet = .newWorkspace }
        .onReceive(of: .meshvyAddRepos) { if store.hasWorkspace { sheet = .addRepos } }
        .onReceive(of: .meshvyUninstall) { store.runUninstaller() }
        .onReceive(of: .meshvyCheckForUpdates) {
            store.updates.check(announceNoUpdate: true)
            sheet = .update
        }
        .onReceive(of: .meshvyOpenOrchestrator) { if store.hasWorkspace { store.startOrchestrator() } }
        .onReceive(of: .meshvyOpenShell) { if store.hasWorkspace { store.openTerminal(role: .shell) } }
        .onReceive(of: .meshvyOpenBrowser) { if store.hasWorkspace { store.openBrowser() } }
        .onReceive(of: .meshvyArchiveWorkspace) {
            if let active = store.activeWorkspace { store.requestArchive(active.id) }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    var body: some View {
        ZStack {
            Theme.canvas
            VStack(spacing: 22) {
                // `square.link.3d.up` stood here, and is not an SF Symbol: the
                // first thing a new install showed was a gap above its title.
                BrandMark(size: 44)

                VStack(spacing: 7) {
                    Text("No workspace yet")
                        .font(Theme.ui(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Put the repositories you work on together on one board, and run an agent in each of them at once.")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 400)
                }

                // What happens, in the order it happens — the paragraph this
                // replaces said all of it in one breath.
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Pick the repositories", "Folders on disk, or a GitHub URL to clone.")
                    step(
                        2, "Meshvy cuts one branch across them",
                        "Each is checked out side by side under ~/.meshvy. Your own clones are left alone."
                    )
                    step(
                        3, "Start the orchestrator",
                        "Claude Code at the workspace root, handing work to an agent in each repository."
                    )
                }
                .frame(maxWidth: 400, alignment: .leading)

                if store.claudeInstalled == false {
                    ClaudeMissingNotice(store: store)
                        .frame(maxWidth: 400)
                }

                VStack(spacing: 7) {
                    PrimaryButton(title: "New workspace") { sheet = .newWorkspace }
                    Text("⇧⌘N")
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }

                if !store.liveWorkspaces.isEmpty {
                    workspaceList("OR OPEN", store.liveWorkspaces)
                }
                // Archiving when it was the last one open lands you here, so
                // the way back has to be on this screen too.
                if !store.archivedWorkspaces.isEmpty {
                    workspaceList("ARCHIVED", store.archivedWorkspaces)
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func workspaceList(_ title: String, _ workspaces: [Workspace]) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(Theme.ui(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            ForEach(workspaces) { workspace in
                Button { store.activate(workspace.id) } label: {
                    Text(workspace.name)
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text("\(number)")
                .font(Theme.mono(10.5, .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent.opacity(0.12)))
                .overlay(Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.ui(12.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Said wherever an agent would otherwise be started from nothing: Meshvy
/// drives the `claude` CLI and does not ship it, and without it every Start
/// button opens a terminal that fails on its first line.
struct ClaudeMissingNotice: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(Theme.dirty)
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code is not installed")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Meshvy runs the claude CLI rather than the API, and a login shell here cannot find it. Install it and sign in once, then come back.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { store.openClaudeCodeInstallPage() } label: {
                    HStack(spacing: 4) {
                        Text("Get Claude Code")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(Theme.ui(11, .semibold))
                    .foregroundStyle(Theme.dirty)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.dirty.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.dirty.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    /// Read on every render rather than held in `@State`, so the bar cannot be
    /// left holding a stale answer — see `WindowChrome`.
    private var chrome: WindowChrome { WindowChrome.shared }

    static let height: CGFloat = 48

    /// The traffic lights run to x=69, so the first control sits just past them
    /// and the panel toggles read as the two ends of the bar. In full screen
    /// the lights go away and the gutter with them — as it does in a snapshot,
    /// which has no window and so no lights to leave room for. `WindowChrome`
    /// cannot tell: its reading is of a window, and there is not one.
    private var leadingInset: CGFloat {
        isSnapshot || !chrome.trafficLightsVisible ? 12 : 78
    }

    var body: some View {
        HStack(spacing: 0) {
            leadingCluster
            Spacer(minLength: 12)
            if store.hasWorkspace {
                trailingCluster
            } else if store.updates.availableRelease != nil {
                UpdatePill(store: store, sheet: $sheet)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background(Theme.chrome)
        .background(
            TrafficLightLayout(barHeight: Self.height)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    /// Panel toggle, identity, then the one action worth filling with accent.
    private var leadingCluster: some View {
        HStack(spacing: 7) {
            ChromeButton(icon: "sidebar.leading", help: "Toggle sidebar (⌥⌘S)", isActive: store.sidebarVisible) {
                store.sidebarVisible.toggle()
            }
            .disabled(!store.hasWorkspace)
            // Dimmed rather than dropped, so the identity block does not shift
            // sideways when a workspace opens.
            .opacity(store.hasWorkspace ? 1 : 0.4)

            barDivider

            BrandMark(size: 17)
                .help("Meshvy")

            workspaceMenu

            if store.hasWorkspace {
                archiveButton
                AccentButton(
                    icon: store.isOrchestratorRunning ? "point.3.connected.trianglepath.dotted" : "play.fill",
                    label: store.isOrchestratorRunning ? "Go to orchestrator" : "Start Claude Code"
                ) {
                    if store.isOrchestratorRunning, let id = store.activeWorkspace?.id {
                        store.reveal(.workspace(id))
                    } else {
                        store.startOrchestrator()
                    }
                }
                .help("Claude Code runs on the workspace node, with every repo beneath it")
                .padding(.leading, 3)

                AgentSettingsPicker(store: store)
            }
        }
    }

    /// Archiving is one click, because nothing it does needs thinking about:
    /// the worktrees stay, the branch stays, and the banner it leaves offers
    /// to undo it. The one case worth a question is archiving a board with
    /// agents still running on it, since that does stop them — which the store
    /// asks about, so ⌥⌘A and the menus ask too.
    @ViewBuilder
    private var archiveButton: some View {
        if let active = store.activeWorkspace {
            ChromeButton(
                icon: "archivebox",
                help: "Archive “\(active.name)” — keeps every worktree (⌥⌘A)"
            ) {
                store.requestArchive(active.id)
            }
        }
    }

    /// View controls, then the inspector toggle mirroring the sidebar one.
    private var trailingCluster: some View {
        HStack(spacing: 7) {
            // It was written, styled and never placed, so a new release only
            // reached anyone who thought to open Check for Updates… themselves.
            if store.updates.availableRelease != nil {
                UpdatePill(store: store, sheet: $sheet)
            }

            needsYouPill

            ChromeButton(icon: "magnifyingglass", help: "Command palette (⌘K)") { store.paletteOpen = true }

            barDivider

            zoomCluster

            ChromeButton(icon: "arrow.clockwise", help: "Refresh everything (⌘R)") { store.refreshAll() }

            barDivider

            ChromeButton(icon: "sidebar.trailing", help: "Toggle inspector (⌥⌘I)", isActive: store.inspectorVisible) {
                store.inspectorVisible.toggle()
            }
        }
    }

    /// How many agents are stuck, as a button that walks you through them.
    @ViewBuilder
    private var needsYouPill: some View {
        let count = store.agentsNeedingYou.count
        if count > 0 {
            Button { store.revealNextNeedingYou() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill").font(Theme.ui(10, .semibold))
                    Text("\(count) need\(count == 1 ? "s" : "") you").font(Theme.ui(11, .semibold))
                }
                .foregroundStyle(Theme.needsYou)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.needsYou.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.needsYou.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Go to the next agent waiting on you (⌥⌘N)")
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Theme.hairlineStrong)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 1)
    }

    private var zoomCluster: some View {
        HStack(spacing: 1) {
            Button { store.zoom(by: 1 / 1.25) } label: {
                Image(systemName: "minus").font(Theme.ui(10, .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)

            Button { store.fit() } label: {
                Text("\(Int((store.viewport.scale * 100).rounded()))%")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 42)
            }
            .buttonStyle(.plain)
            .help("Fit to content (⌘0)")

            Button { store.zoom(by: 1.25) } label: {
                Image(systemName: "plus").font(Theme.ui(10, .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
    }

    private var workspaceMenu: some View {
        SnapshotSafeMenu {
            ForEach(store.liveWorkspaces) { workspace in
                Button {
                    store.activate(workspace.id)
                } label: {
                    Label(
                        workspace.name,
                        systemImage: workspace.id == store.activeWorkspace?.id ? "checkmark" : "rectangle.3.group"
                    )
                }
            }
            if !store.liveWorkspaces.isEmpty { Divider() }
            Button("New workspace…") { sheet = .newWorkspace }
            if let active = store.activeWorkspace {
                Button("Add repositories…") { sheet = .addRepos }
                Button("New browser…") { store.openBrowser() }
                Divider()
                Button("Reveal folder in Finder") { store.revealInFinder(active.root) }
                Divider()
                Button("Archive “\(active.name)”") { store.requestArchive(active.id) }
            }
            if !store.archivedWorkspaces.isEmpty {
                Menu("Archived") {
                    ForEach(store.archivedWorkspaces) { workspace in
                        Button {
                            store.unarchiveWorkspace(workspace.id)
                        } label: {
                            Label(workspace.name, systemImage: "tray.and.arrow.up")
                        }
                    }
                }
            }
            if let active = store.activeWorkspace {
                Divider()
                Button("Close (keep worktrees)…") {
                    store.requestDelete(active.id, removeWorktrees: false, force: false)
                }
                Button("Delete worktrees…") {
                    store.requestDelete(active.id, removeWorktrees: true, force: false)
                }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.activeWorkspace?.name ?? "No workspace")
                        .font(Theme.ui(12.5, .semibold))
                        .foregroundStyle(store.hasWorkspace ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)
                    if let active = store.activeWorkspace {
                        Text(counts(active))
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Image(systemName: "chevron.down").font(Theme.ui(7.5, .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
        }
    }

    private func counts(_ workspace: Workspace) -> String {
        let repos = workspace.repos.count
        return "\(repos) \(repos == 1 ? "repo" : "repos") · \(workspace.branch)"
    }
}

/// Appears only when a newer release exists, and says which.
private struct UpdatePill: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?
    @State private var hovering = false

    var body: some View {
        if let release = store.updates.availableRelease {
            Button { sheet = .update } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill").font(Theme.ui(10.5, .semibold))
                    Text("Update to \(release.version)").font(Theme.ui(11, .semibold))
                }
                .foregroundStyle(Theme.clean)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.clean.opacity(hovering ? 0.22 : 0.14))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Meshvy \(release.version) is available")
        }
    }
}

/// Accent-filled action for the one thing the toolbar most wants you to do.
struct AccentButton: View {
    var icon: String
    var label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(Theme.ui(11, .semibold))
                Text(label).font(Theme.ui(11.5, .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(hovering ? 0.22 : 0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Compact segmented picker used for board grouping.
struct SegmentedControl<Option: Hashable>: View {
    var options: [Option]
    @Binding var selection: Option
    var label: (Option) -> String
    var icon: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(option)).font(Theme.ui(9.5, .semibold))
                        Text(label(option)).font(Theme.ui(10.5, .medium))
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? Theme.fillStrong : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        HStack(spacing: 10) {
            if store.isIndexing || store.isWorking {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            } else {
                Circle().fill(store.hasWorkspace ? Theme.clean : Theme.ended).frame(width: 6, height: 6)
            }
            Text(store.statusLine)
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            // Drawn in the accent like a link, so it had better act like one.
            if store.hasWorkspace, store.totalChangedFiles > 0 {
                Button { store.showWorkspaceChanges() } label: {
                    Text("\(store.totalChangedFiles) changed")
                        .font(Theme.ui(10.5, .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Show every changed file, across every repository")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.chrome)
    }
}

// MARK: - Banner

private struct BannerView: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        if let banner = store.banner {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon(banner.kind))
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(tint(banner.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(banner.title)
                        .font(Theme.ui(12, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let detail = banner.detail {
                        Text(detail)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if let action = banner.action {
                    Spacer(minLength: 8)
                    Button {
                        store.dismissBanner()
                        action.run()
                    } label: {
                        Text(action.label)
                            .font(Theme.ui(11.5, .semibold))
                            .foregroundStyle(tint(banner.kind))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tint(banner.kind).opacity(0.14))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { store.dismissBanner() } label: {
                    Image(systemName: "xmark").font(Theme.ui(9, .bold)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint(banner.kind).opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func icon(_ kind: MeshvyStore.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: MeshvyStore.Banner.Kind) -> Color {
        switch kind {
        case .info: return Theme.info
        case .success: return Theme.clean
        case .failure: return Theme.danger
        }
    }
}

// MARK: - Menu commands
//
// Menu items live in the App scene and the canvas lives several views down, so
// commands are relayed as notifications rather than threaded through bindings.

extension Notification.Name {
    static let meshvyToggleSidebar = Notification.Name("meshvy.toggleSidebar")
    static let meshvyToggleInspector = Notification.Name("meshvy.toggleInspector")
    static let meshvyFocusSearch = Notification.Name("meshvy.focusSearch")
    static let meshvyNewWorkspace = Notification.Name("meshvy.newWorkspace")
    static let meshvyAddRepos = Notification.Name("meshvy.addRepos")
    static let meshvyCheckForUpdates = Notification.Name("meshvy.checkForUpdates")
    static let meshvyUninstall = Notification.Name("meshvy.uninstall")
    static let meshvyOpenOrchestrator = Notification.Name("meshvy.openOrchestrator")
    static let meshvyOpenShell = Notification.Name("meshvy.openShell")
    static let meshvyOpenBrowser = Notification.Name("meshvy.openBrowser")
    static let meshvyArchiveWorkspace = Notification.Name("meshvy.archiveWorkspace")
    static let meshvyPalette = Notification.Name("meshvy.palette")
    static let meshvyShortcuts = Notification.Name("meshvy.shortcuts")
    static let meshvyNextAgent = Notification.Name("meshvy.nextAgent")
}

extension View {
    /// Relays a menu command notification without threading bindings through
    /// every intermediate view.
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
