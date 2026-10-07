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
            case .newStack: NewStackSheet(store: store)
            case .launchAgent(let node): LaunchAgentSheet(store: store, node: node)
            }
        }
        .onAppear { store.bootstrap() }
        .onReceive(of: .forgeToggleSidebar) {
            withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
        }
        .onReceive(of: .forgeToggleInspector) {
            withAnimation(.easeOut(duration: 0.18)) { store.inspectorVisible.toggle() }
        }
        .onReceive(of: .forgeFocusSearch) { sidebarVisible = true }
        .onReceive(of: .forgeNewWorkspace) { sheet = .newWorkspace }
        .onReceive(of: .forgeNewStack) { if store.hasWorkspace { sheet = .newStack } }
        .onReceive(of: .forgeAddRepos) { if store.hasWorkspace { sheet = .addRepos } }
        .onReceive(of: .forgeLaunchAgent) { if store.hasWorkspace { sheet = .launchAgent(store.selection) } }
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
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 38, weight: .thin))
                    .foregroundStyle(Theme.accent.opacity(0.75))

                VStack(spacing: 7) {
                    Text("No workspace yet")
                        .font(Theme.ui(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("""
                    A workspace is the set of repositories you work on together. \
                    Add them once, then cut a stack — the same branch as a worktree \
                    in every repo — and put agents to work across all of it.
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
        HStack(spacing: 10) {
            // Room for the traffic lights, since the title bar is hidden.
            Spacer().frame(width: 68)

            if store.hasWorkspace {
                ChromeButton(icon: "sidebar.leading", isActive: sidebarVisible) {
                    withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(Theme.ui(12, .bold))
                    .foregroundStyle(Theme.accent)
                Text("Forge")
                    .font(Theme.ui(13.5, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            workspaceMenu

            if store.hasWorkspace {
                Divider().frame(height: 18).overlay(Theme.hairline)

                ChromeButton(icon: "plus.rectangle.on.rectangle", label: "New stack") { sheet = .newStack }
                ChromeButton(icon: "sparkles", label: "Launch agent") {
                    sheet = .launchAgent(store.selection)
                }

                Divider().frame(height: 18).overlay(Theme.hairline)

                ChromeButton(
                    icon: "square.stack.3d.up",
                    label: store.grouping.label,
                    isActive: store.grouping == .stack
                ) {
                    store.grouping = store.grouping == .stack ? .repo : .stack
                }
                ChromeButton(icon: "clock.badge.checkmark", label: "Ended", isActive: store.showEndedSessions) {
                    store.showEndedSessions.toggle()
                }

                Spacer(minLength: 12)

                ChromeButton(icon: "minus.magnifyingglass") { store.zoom(by: 1 / 1.25) }
                Text("\(Int((store.viewport.scale * 100).rounded()))%")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 42)
                ChromeButton(icon: "plus.magnifyingglass") { store.zoom(by: 1.25) }
                ChromeButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fit") { store.fit() }
                if store.isSearching {
                    ChromeButton(icon: "scope", label: "Focus matches", isActive: true) { store.focusMatches() }
                }

                Divider().frame(height: 18).overlay(Theme.hairline)

                ChromeButton(icon: "arrow.clockwise") { store.refreshAll() }
                ChromeButton(icon: "sidebar.trailing", isActive: store.inspectorVisible) {
                    withAnimation(.easeOut(duration: 0.18)) { store.inspectorVisible.toggle() }
                }
            } else {
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.chrome)
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(store.workspaces) { workspace in
                Button {
                    store.activate(workspace.id)
                } label: {
                    Label(
                        workspace.name,
                        systemImage: workspace.id == store.activeWorkspace?.id ? "checkmark" : "square.stack.3d.up"
                    )
                }
            }
            if !store.workspaces.isEmpty { Divider() }
            Button("New workspace…") { sheet = .newWorkspace }
            if let active = store.activeWorkspace {
                Button("Add repositories…") { sheet = .addRepos }
                Divider()
                Button("Reveal worktree folder") { store.revealInFinder(active.worktreeRoot) }
                Button("Close “\(active.name)”", role: .destructive) { store.deleteWorkspace(active.id) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.activeWorkspace?.name ?? "No workspace")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(store.hasWorkspace ? Theme.textPrimary : Theme.textTertiary)
                Image(systemName: "chevron.down").font(Theme.ui(8, .bold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
    static let forgeNewStack = Notification.Name("forge.newStack")
    static let forgeAddRepos = Notification.Name("forge.addRepos")
    static let forgeLaunchAgent = Notification.Name("forge.launchAgent")
}

extension View {
    /// Relays a menu command notification without threading bindings through
    /// every intermediate view.
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
