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
    @Environment(\.meshvySnapshotMode) private var isSnapshot
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
    /// Only a live session draws a terminal here. An agent that exits on its
    /// own — `/exit`, a crash, Ctrl-D — leaves its view behind in the registry,
    /// and drawing that would strand the node on a frozen screen with no way to
    /// start another: the board has already collapsed it to its idle height by
    /// then, and the header has dropped the stop button with it.
    private var liveSession: TerminalSession? { isRunning ? session : nil }
    private var activity: AgentActivity? { orchestrator.flatMap { store.activity(for: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            repoStrip
            Divider().overlay(Theme.hairline)
            if isRunning {
                AgentStatusStrip(activity: activity, fallback: workspace.root, zoom: zoom)
                Divider().overlay(Theme.hairline)
            }
            body(for: liveSession)
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous)
                .fill(Theme.surfaceSunken)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(14), style: .continuous)
                .stroke(
                    activity?.state == .blocked ? Theme.needsYou
                        : (isSelected ? Theme.accent : Theme.accent.opacity(isRunning ? 0.5 : 0.25)),
                    lineWidth: isSelected ? max(1.5, zoom.s(2)) : max(0.8, zoom.s(1.2))
                )
        )
        .shadow(color: .black.opacity(0.5), radius: zoom.s(20), y: zoom.s(8))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: zoom.s(8)) {
            if let orchestrator, store.isUnread(orchestrator.id) {
                UnreadDot(zoom: zoom)
            } else {
                Image(systemName: "rectangle.3.group.fill")
                    .font(zoom.font(13, .semibold))
                    .foregroundStyle(Theme.accent)
            }

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

            if let orchestrator, isRunning {
                NodeAgentSettingsButton(store: store, node: orchestrator, zoom: zoom)
            }

            if isRunning {
                if let state = activity?.state, state.badge != nil {
                    AgentBadge(state: state, zoom: zoom)
                } else {
                    HStack(spacing: zoom.s(4)) {
                        Circle().fill(Theme.clean).frame(width: zoom.s(6), height: zoom.s(6))
                        Text("Claude Code")
                            .font(zoom.font(10, .semibold))
                            .foregroundStyle(Theme.clean)
                    }
                }
                Button { store.requestStopOrchestrator() } label: {
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
    ///
    /// A repository has no node of its own on the board; this chip is where it
    /// lives. Clicking it puts its changes in the inspector, and right-clicking
    /// it starts something there.
    private var repoStrip: some View {
        HStack(spacing: zoom.s(5)) {
            ForEach(workspace.repos) { repo in
                let worktree = store.worktrees[repo.worktreePath]
                let tint: SwiftUI.Color = !repo.isReady ? Theme.danger
                    : (worktree?.isDirty == true ? Theme.dirty : Theme.worktree)
                let isShown = store.selection == .worktree(repo.worktreePath)
                Button {
                    store.select(.worktree(repo.worktreePath))
                } label: {
                    HStack(spacing: zoom.s(4)) {
                        Circle().fill(tint).frame(width: zoom.s(5), height: zoom.s(5))
                        Text(repo.name)
                            .font(zoom.font(10.5, .medium))
                            .foregroundStyle(isShown ? Theme.textPrimary : Theme.textSecondary)
                    }
                    .padding(.horizontal, zoom.s(7))
                    .padding(.vertical, zoom.s(3.5))
                    .background(
                        RoundedRectangle(cornerRadius: zoom.s(5), style: .continuous)
                            .fill(isShown ? Theme.accent.opacity(0.16) : Theme.fill)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(repo.failure ?? repo.worktreePath)
                .contextMenu {
                    Button("Open agent terminal here") { store.openTerminal(role: .repo, repoID: repo.id) }
                    Button("Open shell here") { store.openTerminal(role: .shell, repoID: repo.id) }
                    Button("Open a browser here") { store.openBrowser(repoID: repo.id) }
                    Divider()
                    Button("Open in editor") { store.openInEditor(repo.worktreePath) }
                    Button("Reveal in Finder") { store.revealInFinder(repo.worktreePath) }
                    Divider()
                    Button("Copy path") { store.copyToClipboard(repo.worktreePath) }
                    if let branch = worktree?.branch {
                        Button("Copy branch name") { store.copyToClipboard(branch) }
                    }
                }
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
        if let session, isSnapshot {
            TerminalSnapshotText(session: session, zoom: zoom)
        } else if let session, zoom.scale > 0.45 {
            TerminalSurface(session: session, scale: zoom.scale)
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

    /// No `claude` on the PATH a terminal gets. Only a definite answer counts:
    /// while the shell is still being asked, the prompt is the usual one.
    private var claudeMissing: Bool { store.claudeInstalled == false }

    private var startPrompt: some View {
        VStack(spacing: zoom.s(10)) {
            Image(systemName: claudeMissing ? "exclamationmark.triangle" : "point.3.connected.trianglepath.dotted")
                .font(zoom.font(22, .light))
                .foregroundStyle(claudeMissing ? Theme.dirty : Theme.accent.opacity(0.8))
            VStack(spacing: zoom.s(3)) {
                Text(claudeMissing ? "Claude Code is not installed" : "Open Claude Code here")
                    .font(zoom.font(12.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(claudeMissing
                    ? "Meshvy runs the claude CLI, and a login shell here cannot find it. Install it and sign in once, then start the orchestrator."
                    : "Runs at the workspace root, with all \(workspace.repos.count) repos beneath it, and hands work to an agent in each.")
                    .font(zoom.font(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: zoom.s(340))
            }
            HStack(spacing: zoom.s(8)) {
                if claudeMissing {
                    promptButton("arrow.up.right", "Get Claude Code", prominent: true) {
                        store.openClaudeCodeInstallPage()
                    }
                    // The check could be wrong; the terminal will say so if not.
                    promptButton("play.fill", "Start anyway", prominent: false) { store.startOrchestrator() }
                } else {
                    promptButton("play.fill", "Start orchestrator", prominent: true) { store.startOrchestrator() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(zoom.s(14))
        .background(Theme.canvasDeep)
    }

    private func promptButton(
        _ icon: String, _ title: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: zoom.s(5)) {
                Image(systemName: icon).font(zoom.font(10, .bold))
                Text(title).font(zoom.font(11.5, .semibold))
            }
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, zoom.s(14))
            .padding(.vertical, zoom.s(7))
            .background(
                RoundedRectangle(cornerRadius: zoom.s(7), style: .continuous)
                    .fill(prominent ? Theme.accent : Theme.fill)
            )
        }
        .buttonStyle(.plain)
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

/// Draws a terminal's current screen as plain text.
///
/// `ImageRenderer` cannot draw an `NSViewRepresentable`, so a terminal is blank
/// in every `--snapshot`. Reading the emulator's own screen buffer and setting
/// it in a monospaced font keeps documentation shots honest — it is the real
/// output of the real session, just drawn by SwiftUI rather than SwiftTerm.
struct TerminalSnapshotText: View {
    var session: TerminalSession
    var zoom: Zoom

    var body: some View {
        Text(trimmed)
            .font(.system(size: max(5, 7.4 * zoom.scale), design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(zoom.s(6))
            .background(Theme.canvasDeep)
            .clipped()
    }

    /// The emulator pads every row to the full width; the trailing blanks waste
    /// the card and push the real output off the bottom.
    private var trimmed: String {
        session.screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .drop { $0.isEmpty }
            .reversed().drop { $0.isEmpty }.reversed()
            .joined(separator: "\n")
    }
}

/// Hosts a registry-owned terminal view.
///
/// The terminal is laid out at its *world* size and magnified to fill the
/// projected frame. That way zooming scales the text like everything else on
/// the board, instead of the grid reflowing and the glyphs staying 11.5pt
/// however far you zoom in — which was the one thing on the canvas whose size
/// never responded to the zoom control.
struct TerminalSurface: NSViewRepresentable {
    var session: TerminalSession
    /// Canvas zoom. The world size is derived from the frame SwiftUI hands the
    /// container, rather than passed in: the card's chrome (header, status
    /// strip, dividers) comes out of the terminal's share of the node, and
    /// quoting the node's own size here stretched the glyphs by whatever that
    /// chrome happened to be.
    var scale: CGFloat

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: Theme.Hex.canvasDeep).cgColor
        container.addSubview(session.surface)
        container.scale = scale
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FlippedContainer else { return }
        if session.surface.superview !== container {
            session.surface.removeFromSuperview()
            container.addSubview(session.surface)
        }
        container.scale = scale
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    /// Lays the terminal out from the top-left, matching the card.
    final class FlippedContainer: NSView {
        var scale: CGFloat = 1

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            guard let child = subviews.first else { return }
            guard scale > 0.01, frame.width > 1, frame.height > 1 else {
                child.frame = bounds
                return
            }
            // Scale *this* view's coordinate system rather than the terminal's.
            // The container's frame is the projected rect and its bounds are
            // that rect in world units, so everything inside is magnified by
            // exactly the zoom, in both axes — while the terminal's own frame
            // depends only on the node's size, which is what keeps SwiftTerm
            // from recomputing its grid and making every running program redraw
            // on each zoom step.
            let world = CGSize(width: frame.width / scale, height: frame.height / scale)
            setBoundsSize(world)
            child.frame = CGRect(origin: .zero, size: world)
        }
    }
}
