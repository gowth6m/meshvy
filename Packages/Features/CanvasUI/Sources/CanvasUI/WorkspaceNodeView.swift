import AgentsUI
import AppKit
import AppState
import DesignSystem
import MeshvyCore
import MeshvyModels
import SwiftUI
import TerminalKit

// SwiftTerm is not imported here: its `Color` would shadow SwiftUI's. The
// terminal is reached through `TerminalSession.surface` as a plain NSView.

/// The parent node. It names the workspace, lists the repositories that belong
/// to it, and hosts the coordinator — the workspace's main chat — in its body.
///
/// Opening the coordinator here rather than in a floating window is the point:
/// its working directory *is* this workspace, every repository shown in the
/// header is a subdirectory of it, and every thread it starts hangs off it.
public struct WorkspaceNodeView: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    public var workspace: Workspace
    @Bindable public var store: MeshvyStore
    public var zoom: Zoom
    public var isSelected: Bool

    public init(
        workspace: Workspace,
        store: MeshvyStore,
        zoom: Zoom,
        isSelected: Bool
    ) {
        self.workspace = workspace
        self.store = store
        self.zoom = zoom
        self.isSelected = isSelected
    }

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

    public var body: some View {
        VStack(spacing: 0) {
            header
            repoStrip
            Divider().overlay(Theme.hairline)
            if isRunning {
                AgentStatusStrip(activity: activity, fallback: workspace.root, zoom: zoom)
                Divider().overlay(Theme.hairline)
            }
            // Same band as every other node: see `TerminalNodeView`.
            body(for: liveSession)
                .padding(.horizontal, zoom.s(CanvasGeometry.borderGrab))
                .padding(.bottom, zoom.s(CanvasGeometry.borderGrab))
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                .fill(Theme.surfaceSunken)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.Corner.node), style: .continuous)
                .stroke(
                    activity?.state == .blocked ? Theme.needsYou
                        : (isSelected ? Theme.accent : Theme.accent.opacity(isRunning ? 0.5 : 0.25)),
                    lineWidth: isSelected ? max(1.5, zoom.s(2)) : max(0.8, zoom.s(1.2))
                )
        )
        .shadow(color: .black.opacity(0.5), radius: zoom.s(20), y: zoom.s(8))
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
                        Text("Coordinator")
                            .font(zoom.font(10, .semibold))
                            .foregroundStyle(Theme.clean)
                    }
                }
                Button { store.requestStopCoordinator() } label: {
                    Image(systemName: "stop.circle").font(zoom.font(11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Stop the coordinator")
            }
        }
        .padding(.horizontal, zoom.s(12))
        .frame(height: zoom.c(BoardMetrics.Chrome.workspaceHeader))
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
                    Button("New thread here") { store.newThread(repoID: repo.id) }
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
        // A fixed height rather than whatever the chips add up to: the canvas
        // works out where this node's live terminal starts from the same
        // number, and a strip that grew with its content would move that line
        // without telling it. See `CanvasNode.chromeHeight`.
        .frame(height: zoom.c(BoardMetrics.Chrome.repoStrip))
    }

    // MARK: Body

    @ViewBuilder
    private func body(for session: TerminalSession?) -> some View {
        if let session, isSnapshot {
            TerminalSnapshotText(session: session, zoom: zoom)
        } else if let session, zoom.showsLiveContent {
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
            Text("Coordinator running — zoom in to read")
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
            Image(systemName: claudeMissing ? "exclamationmark.triangle" : TerminalNode.Role.orchestrator.icon)
                .font(zoom.font(22, .light))
                .foregroundStyle(claudeMissing ? Theme.dirty : Theme.accent.opacity(0.8))
            VStack(spacing: zoom.s(3)) {
                Text(claudeMissing ? "Claude Code is not installed" : "Start the coordinator")
                    .font(zoom.font(12.5, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(claudeMissing
                    ? "Meshvy runs the claude CLI, and a login shell here cannot find it. Install it and sign in once, then start the coordinator."
                    : "This is the workspace's main chat. Tell it what you want; it starts a thread for each piece of work and reports back here.")
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
                    promptButton("play.fill", "Start anyway", prominent: false) { store.startCoordinator() }
                } else {
                    promptButton("play.fill", "Start coordinator", prominent: true) { store.startCoordinator() }
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
                RoundedRectangle(cornerRadius: zoom.s(6), style: .continuous)
                    .fill(prominent ? Theme.accent : Theme.fill)
            )
        }
        .buttonStyle(.plain)
    }
}
