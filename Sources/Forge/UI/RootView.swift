import Combine
import SwiftUI

struct RootView: View {
    @Bindable var store: ForgeStore
    @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, sidebarVisible: $sidebarVisible)
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                if sidebarVisible {
                    Sidebar(store: store)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().overlay(Theme.hairline)
                }
                CanvasView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if store.inspectorVisible {
                    Divider().overlay(Theme.hairline)
                    InspectorView(store: store)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            Divider().overlay(Theme.hairline)
            StatusBar(store: store)
        }
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onAppear { store.bootstrap() }
        .onReceive(of: .forgeToggleSidebar) {
            withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
        }
        .onReceive(of: .forgeToggleInspector) {
            withAnimation(.easeOut(duration: 0.18)) { store.inspectorVisible.toggle() }
        }
        .onReceive(of: .forgeFocusSearch) {
            sidebarVisible = true
            searchFocused = true
        }
    }
}

private struct TopBar: View {
    @Bindable var store: ForgeStore
    @Binding var sidebarVisible: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Room for the traffic lights, since the title bar is hidden.
            Spacer().frame(width: 68)

            ChromeButton(icon: "sidebar.leading", isActive: sidebarVisible) {
                withAnimation(.easeOut(duration: 0.18)) { sidebarVisible.toggle() }
            }

            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(Theme.ui(12, .bold))
                    .foregroundStyle(Theme.accent)
                Text("Forge")
                    .font(Theme.ui(13.5, .bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.trailing, 4)

            Divider().frame(height: 18).overlay(Theme.hairline)

            ChromeButton(icon: "rectangle.3.group", label: "Group by repo", isActive: store.groupByRepo) {
                store.groupByRepo.toggle()
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

            ChromeButton(icon: "arrow.counterclockwise", label: "Reset layout") { store.resetLayout() }
            ChromeButton(icon: "arrow.clockwise") { store.refreshAll() }
            ChromeButton(icon: "sidebar.trailing", isActive: store.inspectorVisible) {
                withAnimation(.easeOut(duration: 0.18)) { store.inspectorVisible.toggle() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Theme.chrome)
    }
}

private struct StatusBar: View {
    @Bindable var store: ForgeStore

    var body: some View {
        HStack(spacing: 10) {
            if store.isIndexing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            } else {
                Circle().fill(Theme.clean).frame(width: 6, height: 6)
            }
            Text(store.statusLine)
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            Text("drag to pan  ·  scroll to pan  ·  ⌘scroll or pinch to zoom  ·  double-click a card to open")
                .font(Theme.ui(10))
                .foregroundStyle(Theme.textTertiary.opacity(0.75))
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.chrome)
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
}

extension View {
    /// Relays a menu command notification without threading bindings through
    /// every intermediate view.
    func onReceive(of name: Notification.Name, perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
    }
}
