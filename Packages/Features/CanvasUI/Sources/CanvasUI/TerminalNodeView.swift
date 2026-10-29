import AgentsUI
import AppKit
import AppState
import DesignSystem
import MeshvyCore
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
    /// While a handle is being dragged the node follows it, but the grid in it
    /// waits for the release. See `TerminalSurface.holdsGrid`.
    public var isResizing: Bool

    public init(
        node: TerminalNode,
        store: MeshvyStore,
        zoom: Zoom,
        isSelected: Bool,
        isDimmed: Bool,
        isResizing: Bool = false
    ) {
        self.node = node
        self.store = store
        self.zoom = zoom
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.isResizing = isResizing
    }

    private var session: TerminalSession? { store.terminals.session(for: node.id) }
    private var isRunning: Bool { session?.isRunning ?? false }
    private var activity: AgentActivity? { store.activity(for: node) }

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
            // The live surface stops short of the node's own edge, so the band
            // a drag picks the node up by is the node's and not the terminal's.
            // Without it the only way to move a terminal was its header: every
            // other pixel belongs to an AppKit view, which takes the press
            // before SwiftUI ever sees it.
            content
                .padding(.horizontal, zoom.s(CanvasGeometry.borderGrab))
                .padding(.bottom, zoom.s(CanvasGeometry.borderGrab))
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                .fill(Theme.canvasDeep)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : accent.opacity(isRunning ? 0.45 : 0.2),
                    lineWidth: isSelected ? max(1, zoom.s(1.8)) : max(0.5, zoom.s(1))
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.35), radius: zoom.s(isSelected ? 18 : 10), y: zoom.s(5))
        // A resolved thread stays where it was, quieter, until it is needed.
        .opacity(isDimmed ? 0.25 : (node.isResolved ? 0.6 : 1))
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
            if node.isThread {
                // A thread's headline is where it stands, the same pill the
                // sidebar lists it with.
                ThreadStatePill(state: store.threadState(for: node), zoom: zoom)
            } else if let state = activity?.state, state.badge != nil {
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
            .help(node.isThread && isRunning ? "Close the thread and stop its agent" : "Close terminal")
        }
        .padding(.horizontal, zoom.s(10))
        .frame(height: zoom.c(BoardMetrics.Chrome.header))
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
            if zoom.showsLiveContent {
                TerminalSurface(session: session, scale: zoom.scale, holdsGrid: isResizing)
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
}
