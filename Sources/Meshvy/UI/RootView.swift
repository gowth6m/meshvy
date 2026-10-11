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
        .onAppear { store.bootstrap() }
        .onReceive(of: .meshvyPalette) { store.paletteOpen.toggle() }
        .onReceive(of: .meshvyShortcuts) { store.shortcutsOpen.toggle() }
        .onReceive(of: .meshvyNextAgent) { if store.hasWorkspace { store.revealNextNeedingYou() } }
        .onReceive(of: .meshvyToggleSidebar) { store.sidebarVisible.toggle() }
        .onReceive(of: .meshvyToggleInspector) { store.inspectorVisible.toggle() }
        .onReceive(of: .meshvyFocusSearch) { store.sidebarVisible = true }
        .onReceive(of: .meshvyNewWorkspace) { sheet = .newWorkspace }
        .onReceive(of: .meshvyAddRepos) { if store.hasWorkspace { sheet = .addRepos } }
        .onReceive(of: .meshvyCheckForUpdates) {
            store.updates.check(announceNoUpdate: true)
            sheet = .update
        }
        .onReceive(of: .meshvyOpenOrchestrator) { if store.hasWorkspace { store.startOrchestrator() } }
        .onReceive(of: .meshvyOpenShell) { if store.hasWorkspace { store.openTerminal(role: .shell) } }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    var body: some View {
        ZStack {
            Theme.canvas
            VStack(spacing: 18) {
                Image(systemName: "square.link.3d.up")
                    .font(.system(size: 38, weight: .thin))
                    .foregroundStyle(Theme.accent.opacity(0.75))

                VStack(spacing: 7) {
                    Text("No workspace yet")
                        .font(Theme.ui(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("""
                    A workspace is the repositories you work on together, each \
                    checked out on one shared branch under ~/.forge. Open an \
                    orchestrator terminal at its root and it can put a sub-agent \
                    on every repo at once.
                    """)
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }

                PrimaryButton(title: "New workspace") { sheet = .newWorkspace }

                if !store.workspaces.isEmpty {
                    VStack(spacing: 5) {
                        Text("OR OPEN")
                            .font(Theme.ui(9, .heavy))
                            .tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(store.workspaces) { workspace in
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
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?
    @State private var trafficLights = true

    static let height: CGFloat = 48

    /// The traffic lights run to x=69, so the first control sits just past them
    /// and the panel toggles read as the two ends of the bar. In full screen
    /// the lights go away and the gutter with them.
    private var leadingInset: CGFloat { trafficLights ? 78 : 12 }

    var body: some View {
        HStack(spacing: 0) {
            leadingCluster
            Spacer(minLength: 12)
            if store.hasWorkspace { trailingCluster }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background(Theme.chrome)
        .background(
            TrafficLightLayout(barHeight: Self.height) { trafficLights = $0 }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    /// Panel toggle, identity, then the one action worth filling with accent.
    private var leadingCluster: some View {
        HStack(spacing: 7) {
            ChromeButton(icon: "sidebar.leading", isActive: store.sidebarVisible) {
                store.sidebarVisible.toggle()
            }
            .help("Toggle sidebar (⌥⌘S)")
            .disabled(!store.hasWorkspace)
            // Dimmed rather than dropped, so the identity block does not shift
            // sideways when a workspace opens.
            .opacity(store.hasWorkspace ? 1 : 0.4)

            barDivider

            BrandMark(size: 17)
                .help("Meshvy")

            workspaceMenu

            if store.hasWorkspace {
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

                PermissionModePicker(store: store)
            }
        }
    }

    /// View controls, then the inspector toggle mirroring the sidebar one.
    private var trailingCluster: some View {
        HStack(spacing: 7) {
            needsYouPill

            ChromeButton(icon: "magnifyingglass") { store.paletteOpen = true }
                .help("Command palette (⌘K)")

            barDivider

            zoomCluster

            ChromeButton(icon: "arrow.clockwise") { store.refreshAll() }
                .help("Refresh everything (⌘R)")

            barDivider

            ChromeButton(icon: "sidebar.trailing", isActive: store.inspectorVisible) {
                store.inspectorVisible.toggle()
            }
            .help("Toggle inspector (⌥⌘I)")
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
        Menu {
            ForEach(store.workspaces) { workspace in
                Button {
                    store.activate(workspace.id)
                } label: {
                    Label(
                        workspace.name,
                        systemImage: workspace.id == store.activeWorkspace?.id ? "checkmark" : "rectangle.3.group"
                    )
                }
            }
            if !store.workspaces.isEmpty { Divider() }
            Button("New workspace…") { sheet = .newWorkspace }
            if let active = store.activeWorkspace {
                Button("Add repositories…") { sheet = .addRepos }
                Divider()
                Button("Reveal folder in Finder") { store.revealInFinder(active.root) }
                Divider()
                Button("Close (keep worktrees)") {
                    store.deleteWorkspace(active.id, removeWorktrees: false, force: false)
                }
                Button("Delete worktrees") {
                    store.deleteWorkspace(active.id, removeWorktrees: true, force: false)
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                    Text(release.version).font(Theme.ui(11, .semibold))
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
            if store.hasWorkspace, store.totalChangedFiles > 0 {
                Text("\(store.totalChangedFiles) changed")
                    .font(Theme.ui(10.5, .medium))
                    .foregroundStyle(Theme.accent)
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
    static let meshvyOpenOrchestrator = Notification.Name("meshvy.openOrchestrator")
    static let meshvyOpenShell = Notification.Name("meshvy.openShell")
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
