import SwiftUI

/// A Claude session card. Everything on it comes from the transcript on disk
/// plus the live process registry — nothing is inferred.
struct SessionNodeView: View {
    var summary: SessionSummary
    var status: SessionStatus
    var liveSession: LiveSession?
    var zoom: Zoom
    var detail: DetailLevel
    var isSelected: Bool
    var isHovered: Bool
    var isDimmed: Bool

    private var accent: Color {
        switch status {
        case .busy: return Theme.busy
        case .idle: return Theme.idle
        case .ended: return summary.isSidechain ? Theme.sidechain : Theme.ended
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: zoom.s(Theme.accentRail))
            content
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .fill(isHovered ? Theme.surfaceRaised : Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : (status.isLive ? accent.opacity(0.35) : Theme.hairline),
                    lineWidth: isSelected ? max(1, zoom.s(1.6)) : max(0.5, zoom.s(0.8))
                )
        )
        .shadow(
            color: .black.opacity(isSelected || isHovered ? 0.5 : 0),
            radius: isSelected || isHovered ? zoom.s(14) : 0,
            y: isSelected || isHovered ? zoom.s(5) : 0
        )
        .opacity(isDimmed ? 0.22 : 1)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: zoom.s(detail == .full ? 7 : 4)) {
            header
            if detail == .full {
                chips
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text(summary.workspaceName)
                    .font(zoom.mono(10, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, zoom.s(11))
        .padding(.vertical, zoom.s(9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: zoom.s(4)) {
            StatusDot(status: status, zoom: zoom)
                .offset(y: zoom.s(-1))
            Text(summary.displayTitle)
                .font(zoom.font(12.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var chips: some View {
        HStack(spacing: zoom.s(4)) {
            Pill(text: summary.workspaceName, icon: "folder", tint: Theme.textSecondary, zoom: zoom)
            if let branch = summary.gitBranch, !branch.isEmpty {
                Pill(text: branch, icon: "arrow.triangle.branch", tint: Theme.branch, zoom: zoom)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: zoom.s(8)) {
            if let model = Format.model(summary.model) {
                Text(model)
                    .font(zoom.font(9.5, .semibold))
                    .foregroundStyle(accent.opacity(0.95))
            }
            if summary.isIndexed {
                MetaStat(icon: "bubble.left.and.text.bubble.right", value: Format.compactCount(summary.userTurns), zoom: zoom)
                    .help("\(summary.userTurns) prompts from you")
                MetaStat(icon: "wrench.and.screwdriver", value: Format.compactCount(summary.toolCalls), zoom: zoom)
                    .help("\(summary.toolCalls) tool calls")
            } else {
                MetaStat(icon: "clock.arrow.circlepath", value: "…", zoom: zoom)
                    .help("Indexing")
            }
            Spacer(minLength: 0)
            Text(Format.relative(summary.lastActivityAt))
                .font(zoom.font(9.5, .medium))
                .foregroundStyle(status == .busy ? Theme.busy : Theme.textTertiary)
        }
    }
}
