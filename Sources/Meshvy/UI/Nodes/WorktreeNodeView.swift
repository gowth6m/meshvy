import SwiftUI

/// A checkout on disk. Dirty state and divergence are read with
/// `GIT_OPTIONAL_LOCKS=0` so inspecting never fights an agent working in the tree.
struct WorktreeNodeView: View {
    var worktree: Worktree
    var zoom: Zoom
    var detail: DetailLevel
    var isSelected: Bool
    var isHovered: Bool
    var isDimmed: Bool
    var attachedSessions: Int
    var liveSessions: Int

    private var accent: Color {
        if worktree.isArchived || worktree.isPrunable { return Theme.ended }
        if liveSessions > 0 { return Theme.busy }
        return worktree.isDirty ? Theme.dirty : Theme.worktree
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
                .fill(isHovered ? Theme.surfaceRaised : Theme.surfaceSunken)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : Theme.hairlineStrong,
                    lineWidth: isSelected ? max(1, zoom.s(1.6)) : max(0.5, zoom.s(0.8))
                )
        )
        .shadow(
            color: .black.opacity(isSelected || isHovered ? 0.45 : 0),
            radius: isSelected || isHovered ? zoom.s(12) : 0,
            y: isSelected || isHovered ? zoom.s(4) : 0
        )
        .opacity(isDimmed ? 0.22 : (worktree.isArchived ? 0.72 : 1))
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: zoom.s(detail == .full ? 6 : 4)) {
            header
            if detail == .full {
                HStack(spacing: zoom.s(4)) {
                    Pill(text: worktree.branchLabel, icon: "arrow.triangle.branch", tint: Theme.branch, zoom: zoom)
                    if let ahead = worktree.ahead, let behind = worktree.behind, ahead + behind > 0 {
                        Pill(
                            text: "\(ahead)↑ \(behind)↓",
                            tint: ahead > 0 ? Theme.accent : Theme.textSecondary,
                            zoom: zoom
                        )
                        .help("\(ahead) ahead, \(behind) behind \(worktree.upstream ?? "upstream")")
                    }
                }
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text(worktree.branchLabel)
                    .font(zoom.mono(10, .medium))
                    .foregroundStyle(Theme.branch)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, zoom.s(11))
        .padding(.vertical, zoom.s(9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: zoom.s(5)) {
            Image(systemName: glyph)
                .font(zoom.font(10.5, .medium))
                .foregroundStyle(accent)
            Text(worktree.name)
                .font(zoom.font(12.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if worktree.isArchived {
                Text("ARCHIVED")
                    .font(zoom.font(7.5, .heavy))
                    .tracking(zoom.s(0.4))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, zoom.s(3.5))
                    .padding(.vertical, zoom.s(1))
                    .background(
                        RoundedRectangle(cornerRadius: zoom.s(3))
                            .fill(Theme.fill)
                    )
                    .help("This directory no longer exists — its sessions are kept here")
            } else if worktree.isMain {
                Text("MAIN")
                    .font(zoom.font(7.5, .heavy))
                    .tracking(zoom.s(0.4))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, zoom.s(3.5))
                    .padding(.vertical, zoom.s(1))
                    .background(
                        RoundedRectangle(cornerRadius: zoom.s(3))
                            .fill(Theme.fill)
                    )
            }
            Spacer(minLength: 0)
            if worktree.isLocked {
                Image(systemName: "lock.fill").font(zoom.font(8.5)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var glyph: String {
        if worktree.isArchived { return "archivebox" }
        return worktree.isMain ? "shippingbox.fill" : "square.on.square"
    }

    private var footer: some View {
        HStack(spacing: zoom.s(8)) {
            if worktree.isArchived {
                MetaStat(icon: "clock.arrow.circlepath", value: "no longer on disk", zoom: zoom)
            } else if worktree.hasStatus {
                if worktree.isDirty {
                    MetaStat(
                        icon: "pencil.line",
                        value: "\(worktree.dirtyFiles ?? 0)" + ((worktree.untrackedFiles ?? 0) > 0 ? "+\(worktree.untrackedFiles ?? 0)" : ""),
                        tint: Theme.dirty,
                        zoom: zoom
                    )
                    .help("\(worktree.dirtyFiles ?? 0) modified, \(worktree.untrackedFiles ?? 0) untracked")
                } else {
                    MetaStat(icon: "checkmark.seal", value: "clean", tint: Theme.clean, zoom: zoom)
                }
            } else {
                MetaStat(icon: "ellipsis", value: "", zoom: zoom)
            }
            if attachedSessions > 0 {
                MetaStat(
                    icon: "square.link.3d.up",
                    value: liveSessions > 0 ? "\(attachedSessions) · \(liveSessions) live" : "\(attachedSessions)",
                    tint: liveSessions > 0 ? Theme.busy : Theme.textTertiary,
                    zoom: zoom
                )
                .help("\(attachedSessions) sessions in this worktree")
            }
            Spacer(minLength: 0)
            if let date = worktree.lastCommitDate {
                Text(Format.relative(date))
                    .font(zoom.font(9.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
