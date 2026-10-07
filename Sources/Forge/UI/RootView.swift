import Combine
import SwiftUI

struct RootView: View {
    @Bindable var store: ForgeStore
    @State private var sidebarVisible = true
    @State private var sheet: ForgeSheet?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, sidebarVisible: $sidebarVisible, sheet: $sheet)
            Divider().overlay(Theme.hairline)

            if store.hasWorkspace {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        Sidebar(store: store, sheet: $sheet)
                        Divider().overlay(Theme.hairline)
                    }
                    CanvasView(store: store, sheet: $sheet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if store.inspectorVisible {
                        Divider().overlay(Theme.hairline)
                        InspectorView(store: store, sheet: $sheet)
                    }
                }
            } else {
                EmptyStateView(store: store, sheet: $sheet)
            }

            Divider().overlay(Theme.hairline)
            StatusBar(store: store)
        }
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { BannerView(store: store) }
        .sheet(item: $sheet) { which in
            switch which {
            case .newWorkspace: NewWorkspaceSheet(store: store)
            case .addRepos: AddReposSheet(store: store)
            }
        }
        .onAppear { store.bootstrap() }
        .onReceive(of: .forgeToggleSidebar) { sidebarVisible.toggle() }
        .onReceive(of: .forgeToggleInspector) { store.inspectorVisible.toggle() }
        .onReceive(of: .forgeFocusSearch) { sidebarVisible = true }
        .onReceive(of: .forgeNewWorkspace) { sheet = .newWorkspace }
        .onReceive(of: .forgeAddRepos) { if store.hasWorkspace { sheet = .addRepos } }
        .onReceive(of: .forgeOpenOrchestrator) { if store.hasWorkspace { store.openTerminal(role: .orchestrator) } }
        .onReceive(of: .forgeOpenShell) { if store.hasWorkspace { store.openTerminal(role: .shell) } }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Bindable var store: ForgeStore
    @Binding var sheet: ForgeSheet?

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
    @Bindable var store: ForgeStore
    @Binding var sidebarVisible: Bool
    @Binding var sheet: ForgeSheet?

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights, since the title bar is hidden.
            Spacer().frame(width: 68)

            if store.hasWorkspace {
                ChromeButton(icon: "sidebar.leading", isActive: sidebarVisible) {
                    sidebarVisible.toggle()
                }
            }

            Image(systemName: "flame.fill")
                .font(Theme.ui(12.5, .bold))
                .foregroundStyle(Theme.accent)

            workspaceMenu

            if store.hasWorkspace {
                Divider().frame(height: 16).overlay(Theme.hairline).padding(.horizontal, 2)

                AccentButton(icon: "point.3.connected.trianglepath.dotted", label: "Orchestrator") {
                    store.openTerminal(role: .orchestrator)
                }
                .help("Opens a Claude terminal at the workspace root, with every repo beneath it")
                ChromeButton(icon: "terminal", label: "Shell") {
                    store.openTerminal(role: .shell)
                }

                Spacer(minLength: 16)


                ChromeButton(
                    icon: "clock.badge.checkmark",
                    label: "Ended",
                    isActive: store.showEndedSessions
                ) {
                    store.showEndedSessions.toggle()
                }
                .help("Show sessions that have ended")

                zoomCluster

                ChromeButton(icon: "arrow.clockwise") { store.refreshAll() }
                    .help("Refresh everything (⌘R)")
                ChromeButton(icon: "sidebar.trailing", isActive: store.inspectorVisible) {
                    store.inspectorVisible.toggle()
                }
            } else {
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Theme.chrome)
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
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
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
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
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
                            .fill(selected ? Color.white.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @Bindable var store: ForgeStore

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
            if store.hasWorkspace {
                Text("drag to pan  ·  scroll to pan  ·  ⌘scroll or pinch to zoom  ·  double-click a card to open")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.textTertiary.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.chrome)
    }
}

// MARK: - Banner

private struct BannerView: View {
    @Bindable var store: ForgeStore

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

    private func icon(_ kind: ForgeStore.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: ForgeStore.Banner.Kind) -> Color {
        switch kind {
        case .info: return Theme.sidechain
        case .success: return Theme.clean
        case .failure: return Theme.dirty
        }
    }
}

// MARK: - Menu commands
//
// Menu items live in the App scene and the canvas lives several views down, so
// commands are relayed as notifications rather than threaded through bindings.

extension Notification.Name {
    static let forgeToggleSidebar = Notification.Name("forge.toggleSidebar")
    static let forgeToggleInspector = Notification.Name("forge.toggleInspector")
    static let forgeFocusSearch = Notification.Name("forge.focusSearch")
    static let forgeNewWorkspace = Notification.Name("forge.newWorkspace")
    static let forgeAddRepos = Notification.Name("forge.addRepos")
    static let forgeOpenOrchestrator = Notification.Name("forge.openOrchestrator")
    static let forgeOpenShell = Notification.Name("forge.openShell")
}

extension View {
    /// Relays a menu command notification without threading bindings through
    /// every intermediate view.
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
