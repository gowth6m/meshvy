import SwiftUI

/// The two words the four-state model collapses into on a node header.
///
/// A badge only appears when there is something to say — an agent quietly
/// waiting at its prompt is the resting state of the board and should not
/// compete for attention with one that is stuck.
struct AgentBadge: View {
    var state: AgentState
    var zoom: Zoom
    @State private var pulsing = false

    private var tint: Color {
        switch state {
        case .working: return Theme.busy
        case .blocked: return Theme.needsYou
        case .waiting, .done, .ended: return Theme.textTertiary
        }
    }

    var body: some View {
        if let label = state.badge {
            HStack(spacing: zoom.s(4)) {
                Circle()
                    .fill(tint)
                    .frame(width: zoom.s(5), height: zoom.s(5))
                    .opacity(pulsing ? 0.25 : 1)
                Text(label)
                    .font(zoom.font(7.5, .heavy))
                    .tracking(zoom.s(0.6))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, zoom.s(5))
            .padding(.vertical, zoom.s(2))
            .background(
                RoundedRectangle(cornerRadius: zoom.s(3.5), style: .continuous)
                    .fill(tint.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: zoom.s(3.5), style: .continuous)
                    .stroke(tint.opacity(0.4), lineWidth: max(0.5, zoom.s(0.6)))
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 0.75).repeatForever()) { pulsing = true }
            }
        }
    }
}

/// A fixed strip under a terminal's header saying what its agent is doing.
///
/// Always present, even with nothing to report. A strip that appeared and
/// vanished with each tool call would resize the terminal under it, and
/// SwiftTerm reflows its whole grid on a resize — every running program would
/// redraw a few times a second.
struct AgentStatusStrip: View {
    var activity: AgentActivity?
    /// Shown when the terminal has no agent in it, or none has reported yet.
    var fallback: String
    var zoom: Zoom

    private var tint: Color {
        switch activity?.state {
        case .working: return Theme.busy
        case .blocked: return Theme.needsYou
        case .done: return Theme.clean
        default: return Theme.textTertiary
        }
    }

    private var text: String {
        guard let activity else { return fallback }
        return activity.line ?? activity.state.label
    }

    private var icon: String {
        switch activity?.state {
        case .working: return "circle.dotted"
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark"
        case .waiting: return "pause"
        default: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: zoom.s(5)) {
            Image(systemName: icon).font(zoom.font(8, .semibold))
            Text(text)
                .font(zoom.mono(9, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let activity, activity.toolCalls > 0 {
                Text("\(activity.toolCalls) tools")
                    .font(zoom.font(8.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, zoom.s(10))
        .frame(height: zoom.s(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(activity?.state == .waiting || activity == nil ? 0.04 : 0.09))
    }
}

/// Marks a node that changed while you were looking somewhere else. Cleared
/// the moment the node is selected.
struct UnreadDot: View {
    var zoom: Zoom

    var body: some View {
        Circle()
            .fill(Theme.needsYou)
            .frame(width: zoom.s(6), height: zoom.s(6))
            .overlay(Circle().stroke(Theme.chrome, lineWidth: max(0.5, zoom.s(1))))
            .help("Changed while you were away")
    }
}

/// Picks the mode the *next* agent starts in. A running session's mode can only
/// be changed from inside it with ⇧⇥, so this never claims to retune one.
struct PermissionModePicker: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        SnapshotSafeMenu {
            ForEach(PermissionMode.allCases) { mode in
                Button {
                    store.permissionMode = mode
                } label: {
                    Label(
                        mode.isRisky ? "\(mode.label) — nothing will stop it" : mode.label,
                        systemImage: mode == store.permissionMode ? "checkmark" : mode.icon
                    )
                }
            }
            Divider()
            Text("Applies to agents you start from now on. ⇧⇥ cycles the mode inside a running session.")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.permissionMode.icon).font(Theme.ui(10, .semibold))
                Text(store.permissionMode.label).font(Theme.ui(10.5, .medium))
            }
            .foregroundStyle(store.permissionMode.isRisky ? Theme.dirty : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
        }
        .help("Permission mode new agents start in")
    }
}
