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

/// Model, effort and permission mode — the three things a Claude Code session is
/// launched with — in one menu.
///
/// The same menu serves the toolbar and a node header, and the difference is
/// `node`. With one, the choice is applied to that session where the CLI allows
/// it: `/model` and `/effort` are real commands, so those take effect
/// immediately; the permission mode is not, so that one says how to change it
/// rather than quietly doing nothing.
///
/// Either way the choice is remembered, so the next agent you open starts the
/// way the last one ended up.
struct AgentSettingsMenu<Trigger: View>: View {
    @Bindable var store: MeshvyStore
    /// Session to retune as well as the default. Nil sets only the default.
    var node: TerminalNode?
    @ViewBuilder var trigger: Trigger

    var body: some View {
        SnapshotSafeMenu {
            Section("Model") {
                ForEach(store.models.models, id: \.key) { model in
                    Button {
                        store.selectModel(model.id, applyingTo: node)
                    } label: {
                        Label(
                            model.displayName,
                            systemImage: model.id == store.models.selectedModelID ? "checkmark" : "cpu"
                        )
                    }
                }
            }
            Section("Effort") {
                ForEach(AgentEffort.allCases) { effort in
                    Button {
                        store.selectEffort(effort, applyingTo: node)
                    } label: {
                        Label(
                            effort.label,
                            systemImage: effort == store.agentEffort ? "checkmark" : effort.icon
                        )
                    }
                }
            }
            Section("Permission mode") {
                ForEach(PermissionMode.allCases) { mode in
                    Button {
                        store.selectPermissionMode(mode, notifyingAbout: node)
                    } label: {
                        Label(
                            mode.isRisky ? "\(mode.label) — nothing will stop it" : mode.label,
                            systemImage: mode == store.permissionMode ? "checkmark" : mode.icon
                        )
                    }
                }
            }
            Divider()
            if let node {
                Button("Restart \(node.title) with these settings") {
                    store.restartTerminal(node.id)
                }
                Text("Model and effort take effect now. The permission mode needs a restart, or ⇧⇥ inside the session.")
            } else {
                Text("Applies to agents you start from now on, and is remembered for next time.")
            }
        } label: {
            trigger
        }
    }
}

/// Toolbar form: one pill saying what the next agent will be.
struct AgentSettingsPicker: View {
    @Bindable var store: MeshvyStore

    var body: some View {
        AgentSettingsMenu(store: store) {
            HStack(spacing: 4) {
                Image(systemName: store.permissionMode.icon).font(Theme.ui(10, .semibold))
                Text(AgentSettingsSummary.text(store: store))
                    .font(Theme.ui(10.5, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(store.permissionMode.isRisky ? Theme.dirty : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
        }
        .help("Model, effort and permission mode for the agents you start")
    }
}

/// Node form: the same menu on a card header, which also retunes that session.
struct NodeAgentSettingsButton: View {
    @Bindable var store: MeshvyStore
    var node: TerminalNode
    var zoom: Zoom

    var body: some View {
        AgentSettingsMenu(store: store, node: node) {
            HStack(spacing: zoom.s(3)) {
                Image(systemName: "slider.horizontal.3").font(zoom.font(8.5, .semibold))
                Text(AgentSettingsSummary.short(node: node, store: store))
                    .font(zoom.font(9, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, zoom.s(4))
            .padding(.vertical, zoom.s(1.5))
            .background(RoundedRectangle(cornerRadius: zoom.s(3)).fill(Theme.fill))
        }
        .help("Model, effort and permission mode")
    }
}

/// The wording shared by both forms, so the toolbar and a card never disagree
/// about what an agent is set to.
@MainActor
enum AgentSettingsSummary {
    /// Everything, for the toolbar: model, then effort and mode when they are
    /// not the resting values.
    static func text(store: MeshvyStore) -> String {
        var parts = [model(store.models.selectedModelID, store: store)]
        if store.agentEffort != .inherit { parts.append(store.agentEffort.shortLabel) }
        parts.append(store.permissionMode.label)
        return parts.joined(separator: " · ")
    }

    /// Just enough for a node header, which has a title to fit as well.
    static func short(node: TerminalNode, store: MeshvyStore) -> String {
        var parts = [model(node.model, store: store)]
        if let effort = node.effort, effort != .inherit { parts.append(effort.shortLabel) }
        return parts.joined(separator: " · ")
    }

    private static func model(_ id: String?, store: MeshvyStore) -> String {
        guard let id else { return "CLI default" }
        return Format.model(id) ?? store.models.displayName(for: id)
    }
}
