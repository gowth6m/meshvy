import AgentsUI
import AppKit
import AppState
import DesignSystem
import MeshvyModels
import SwiftUI
import TerminalKit

// SwiftTerm exports its own `Color`, which would shadow SwiftUI's throughout
// this file, so it is not imported here — the terminal view is reached through
// `TerminalSession` and typed as a plain `NSView`.

/// A live terminal sitting on the canvas.
///
/// The `LocalProcessTerminalView` is owned by `TerminalRegistry`, not created
/// here — SwiftUI rebuilds this view on every pan and zoom, and making the view
/// in `makeNSView` would kill and restart the shell each time.
public struct TerminalNodeView: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    public var node: TerminalNode
    @Bindable public var store: MeshvyStore
    public var zoom: Zoom
    public var isSelected: Bool
    public var isDimmed: Bool
    public var onResize: (CGSize) -> Void

    public init(
        node: TerminalNode,
        store: MeshvyStore,
        zoom: Zoom,
        isSelected: Bool,
        isDimmed: Bool,
        onResize: @escaping (CGSize) -> Void
    ) {
        self.node = node
        self.store = store
        self.zoom = zoom
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.onResize = onResize
    }

    private var session: TerminalSession? { store.terminals.session(for: node.id) }
    private var isRunning: Bool { session?.isRunning ?? false }
    private var activity: AgentActivity? { store.activity(for: node) }
    private var isArmed: Bool { store.armedTerminal == node.id }

    private var accent: SwiftUI.Color {
        // An agent that needs you takes over the card's accent, so a board you
        // are panning across tells you where to look before you read anything.
        if activity?.state == .blocked { return Theme.needsYou }
        switch node.role {
        case .orchestrator: return Theme.accent
        case .repo: return Theme.worktree
        case .shell: return Theme.textSecondary
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if node.sessionID != nil {
                AgentStatusStrip(
                    activity: activity,
                    fallback: node.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    zoom: zoom
                )
                Divider().overlay(Theme.hairline)
            }
            content
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .fill(Theme.canvasDeep)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : accent.opacity(isRunning ? 0.45 : 0.2),
                    lineWidth: isSelected ? max(1, zoom.s(1.8)) : max(0.5, zoom.s(1))
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.35), radius: zoom.s(isSelected ? 18 : 10), y: zoom.s(5))
        .opacity(isDimmed ? 0.25 : 1)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .overlay(alignment: .bottom) { scrollHint }
    }

    private var header: some View {
        HStack(spacing: zoom.s(6)) {
            if store.isUnread(node.id) {
                UnreadDot(zoom: zoom)
            } else {
                Image(systemName: node.role.icon)
                    .font(zoom.font(10, .semibold))
                    .foregroundStyle(accent)
            }
            Text(node.title)
                .font(zoom.font(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let state = activity?.state, state.badge != nil {
                AgentBadge(state: state, zoom: zoom)
            } else {
                Text(node.role.label.uppercased())
                    .font(zoom.font(7.5, .heavy))
                    .tracking(zoom.s(0.5))
                    .foregroundStyle(accent.opacity(0.9))
                    .padding(.horizontal, zoom.s(4))
                    .padding(.vertical, zoom.s(1.5))
                    .background(RoundedRectangle(cornerRadius: zoom.s(3)).fill(accent.opacity(0.14)))
            }

            Spacer(minLength: 0)

            // Only for a running agent: a plain shell has no model, no effort
            // and no permission mode, and an exited one cannot be retuned.
            if node.sessionID != nil, isRunning {
                NodeAgentSettingsButton(store: store, node: node, zoom: zoom)
            }

            if !isRunning {
                Text("exited")
                    .font(zoom.font(9.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                Button { store.restartTerminal(node.id) } label: {
                    Image(systemName: "arrow.clockwise").font(zoom.font(9.5, .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Restart")
            } else {
                Circle().fill(Theme.clean).frame(width: zoom.s(5), height: zoom.s(5))
            }

            Button { store.requestClose(node.id) } label: {
                Image(systemName: "xmark").font(zoom.font(9, .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help(node.sessionID != nil && isRunning ? "Close terminal and stop the agent" : "Close terminal")
        }
        .padding(.horizontal, zoom.s(10))
        .frame(height: zoom.s(28))
        .background(Theme.chrome)
    }

    @ViewBuilder
    private var content: some View {
        if let session, isSnapshot {
            TerminalSnapshotText(session: session, zoom: zoom)
        } else if let session {
            // Below roughly half scale the glyphs are unreadable anyway, and the
            // emulator does not scale — show the folder instead and keep the
            // process running untouched in the registry.
            if zoom.scale > 0.5 {
                TerminalSurface(session: session, scale: zoom.scale)
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: zoom.s(5)) {
            Image(systemName: "terminal")
                .font(zoom.font(16, .light))
                .foregroundStyle(Theme.textTertiary)
            Text(node.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(zoom.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasDeep)
    }

    /// The wheel pans the canvas by default, so a terminal has to be dwelled on
    /// before it gets the scrollback. That is invisible unless it says so —
    /// shown only while the pointer is over this terminal and the dwell has not
    /// completed, then it goes away.
    @ViewBuilder
    private var scrollHint: some View {
        if store.hoveredTerminal == node.id, !isArmed, zoom.scale > 0.5 {
            // "Still", because it is a pause and not a press: "hold to
            // scroll" read as press-and-hold, which does something else.
            Text("hold still to scroll")
                .font(zoom.font(8.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, zoom.s(6))
                .padding(.vertical, zoom.s(2))
                .background(Capsule().fill(Theme.chrome.opacity(0.9)))
                .padding(.bottom, zoom.s(6))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(zoom.font(8, .bold))
            .foregroundStyle(Theme.textTertiary)
            .padding(zoom.s(4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onResize(CGSize(
                            width: max(320, node.size.width + value.translation.width / zoom.scale),
                            height: max(200, node.size.height + value.translation.height / zoom.scale)
                        ))
                    }
                    .onEnded { _ in store.commitTerminalMove() }
            )
    }
}
