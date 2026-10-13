import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI

/// A sub-agent the orchestrator dispatched, shown as its own node.
///
/// These are Agent-tool calls inside the orchestrator's session, not separate
/// processes, so everything here is read out of the parent's transcript.
public struct SubAgentNodeView: View {
    public var agent: SubAgent
    public var zoom: Zoom
    public var isSelected: Bool
    public var isDimmed: Bool

    public init(
        agent: SubAgent,
        zoom: Zoom,
        isSelected: Bool,
        isDimmed: Bool
    ) {
        self.agent = agent
        self.zoom = zoom
        self.isSelected = isSelected
        self.isDimmed = isDimmed
    }
    @State private var pulsing = false

    private var tint: SwiftUI.Color {
        switch agent.state {
        case .running: return Theme.busy
        case .finished(let ok): return ok ? Theme.clean : Theme.danger
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: zoom.s(Theme.accentRail))
            VStack(alignment: .leading, spacing: zoom.t(5)) {
                header
                Text(agent.state.isRunning ? agent.prompt : (agent.result ?? agent.prompt))
                    .font(zoom.font(10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, zoom.t(10))
            .padding(.vertical, zoom.t(8))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .fill(Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .stroke(isSelected ? Theme.accent : tint.opacity(0.3), lineWidth: isSelected ? max(1, zoom.s(1.6)) : max(0.5, zoom.s(0.8)))
        )
        .opacity(isDimmed ? 0.22 : 1)
    }

    private var header: some View {
        HStack(spacing: zoom.t(5)) {
            if agent.state.isRunning {
                Circle()
                    .fill(tint)
                    .frame(width: zoom.s(6), height: zoom.s(6))
                    .opacity(pulsing ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            } else {
                Image(systemName: agent.state == .finished(ok: true) ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(zoom.font(9))
                    .foregroundStyle(tint)
            }
            Text(agent.title)
                .font(zoom.font(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: zoom.t(7)) {
            Text(agent.subtitle)
                .font(zoom.font(9, .medium))
                .foregroundStyle(tint.opacity(0.9))
            Spacer(minLength: 0)
            if let tokens = agent.totalTokens {
                MetaStat(icon: "number", value: Format.compactCount(tokens), zoom: zoom)
            }
            if agent.state.isRunning {
                Text("working")
                    .font(zoom.font(9, .semibold))
                    .foregroundStyle(Theme.busy)
            } else if let finished = agent.finishedAt {
                Text(Format.relative(finished))
                    .font(zoom.font(9))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
