import AppKit
import SwiftUI

// SwiftTerm is not imported here: its `Color` would shadow SwiftUI's. The
// terminal is reached through `TerminalSession.surface` as a plain NSView.

/// The parent node. It names the workspace, lists the repositories that belong
/// to it, and hosts the orchestrator's Claude Code session in its body.
///
/// Opening Claude Code here rather than in a floating window is the point: the
/// orchestrator's working directory *is* this workspace, and every repository
/// shown in the header is a subdirectory of it.
struct WorkspaceNodeView: View {
    var workspace: Workspace
    @Bindable var store: MeshvyStore
    var zoom: Zoom
    var isSelected: Bool
    var onResize: (CGSize) -> Void

    private var orchestrator: TerminalNode? { workspace.orchestrator }
    private var session: TerminalSession? {
        orchestrator.flatMap { store.terminals.session(for: $0.id) }
    }
    private var isRunning: Bool { session?.isRunning ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            repoStrip
            Divider().overlay(Theme.hairline)
            body(for: session)
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous)
                .fill(Theme.surfaceSunken)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : Theme.accent.opacity(isRunning ? 0.5 : 0.25),
                    lineWidth: isSelected ? max(1.5, zoom.s(2)) : max(0.8, zoom.s(1.2))
                )
        )
        .shadow(color: .black.opacity(0.5), radius: zoom.s(20), y: zoom.s(8))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: zoom.s(8)) {
            Image(systemName: "rectangle.3.group.fill")
                .font(zoom.font(13, .semibold))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: zoom.s(1)) {
                Text(workspace.name)
                    .font(zoom.font(14, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: zoom.s(5)) {
                    Image(systemName: "arrow.triangle.branch").font(zoom.font(8))
                    Text(workspace.branch).font(zoom.mono(9.5, .medium))
                }
                .foregroundStyle(Theme.branch)
            }

            Spacer(minLength: 0)

            if isRunning {
                HStack(spacing: zoom.s(4)) {
                    Circle().fill(Theme.clean).frame(width: zoom.s(6), height: zoom.s(6))
                    Text("Claude Code")
                        .font(zoom.font(10, .semibold))
                        .foregroundStyle(Theme.clean)
                }
                Button { store.stopOrchestrator() } label: {
                    Image(systemName: "stop.circle").font(zoom.font(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Stop the orchestrator")
            }
        }
        .padding(.horizontal, zoom.s(12))
        .frame(height: zoom.s(42))
    }

    /// Which repositories belong to this workspace, and how each one is doing.
    private var repoStrip: some View {
        HStack(spacing: zoom.s(5)) {
            ForEach(workspace.repos) { repo in
                let worktree = store.worktrees[repo.worktreePath]
                let tint: SwiftUI.Color = !repo.isReady ? Theme.dirty
                    : (worktree?.isDirty == true ? Theme.dirty : Theme.worktree)
                Button {
                    store.reveal(.worktree(repo.worktreePath))
                } label: {
                    HStack(spacing: zoom.s(4)) {
                        Circle().fill(tint).frame(width: zoom.s(5), height: zoom.s(5))
                        Text(repo.name)
                            .font(zoom.font(10.5, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, zoom.s(7))
                    .padding(.vertical, zoom.s(3.5))
                    .background(
                        RoundedRectangle(cornerRadius: zoom.s(5), style: .continuous)
                            .fill(SwiftUI.Color.white.opacity(0.05))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(repo.failure ?? repo.worktreePath)
            }
            Spacer(minLength: 0)
            Text("\(workspace.repos.count) \(workspace.repos.count == 1 ? "repo" : "repos")")
                .font(zoom.font(9.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, zoom.s(12))
        .padding(.bottom, zoom.s(9))
    }

    // MARK: Body

    @ViewBuilder
    private func body(for session: TerminalSession?) -> some View {
        if let session, zoom.scale > 0.45 {
            TerminalSurface(session: session)
        } else if session != nil {
            zoomedOutPlaceholder
        } else {
            startPrompt
        }
    }

    private var zoomedOutPlaceholder: some View {
        VStack(spacing: zoom.s(5)) {
            Image(systemName: "terminal.fill").font(zoom.font(15)).foregroundStyle(Theme.accent.opacity(0.6))
            Text("Claude Code running — zoom in to read")
                .font(zoom.font(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasDeep)
    }

    private var startPrompt: some View {
        VStack(spacing: zoom.s(10)) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(zoom.font(22, .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
            VStack(spacing: zoom.s(3)) {
                Text("Open Claude Code here")
                    .font(zoom.font(12.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Runs at the workspace root, with all \(workspace.repos.count) repos beneath it. It will split work into sub-agents.")
                    .font(zoom.font(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: zoom.s(340))
            }
            Button { store.startOrchestrator() } label: {
                HStack(spacing: zoom.s(5)) {
                    Image(systemName: "play.fill").font(zoom.font(10, .bold))
                    Text("Start orchestrator").font(zoom.font(11.5, .semibold))
                }
                .foregroundStyle(Theme.brandCream)
                .padding(.horizontal, zoom.s(14))
                .padding(.vertical, zoom.s(7))
                .background(RoundedRectangle(cornerRadius: zoom.s(7), style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(zoom.s(14))
        .background(Theme.canvasDeep)
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(zoom.font(8, .bold))
            .foregroundStyle(Theme.textTertiary)
            .padding(zoom.s(5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onResize(CGSize(
                            width: max(420, workspace.boardWidth + value.translation.width / zoom.scale),
                            height: max(260, workspace.boardHeight + value.translation.height / zoom.scale)
                        ))
                    }
                    .onEnded { _ in store.commitTerminalMove() }
            )
            .opacity(isRunning ? 1 : 0)
    }
}

/// Hosts a registry-owned terminal view.
struct TerminalSurface: NSViewRepresentable {
    var session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.035, green: 0.039, blue: 0.051, alpha: 1).cgColor
        container.addSubview(session.surface)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if session.surface.superview !== nsView {
            session.surface.removeFromSuperview()
            nsView.addSubview(session.surface)
        }
        session.surface.frame = nsView.bounds
    }

    /// Lays the terminal out from the top-left, matching the card.
    final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds
        }
    }
}
