import SwiftUI

/// Right panel: everything known about the selected node, plus the transcript
/// reader for sessions.
struct InspectorView: View {
    @Bindable var store: ForgeStore
    @Binding var sheet: ForgeSheet?

    var body: some View {
        VStack(spacing: 0) {
            if let selection = store.selection, let node = store.graph.node(selection) {
                switch node.kind {
                case .session(let summary, let status, let live):
                    sessionInspector(summary, status: status, live: live)
                case .worktree(let worktree):
                    worktreeInspector(worktree, repoID: node.repoID)
                case .terminal(let terminal):
                    terminalInspector(terminal)
                case .workspace(let workspace):
                    workspaceInspector(workspace)
                case .subAgent(let agent):
                    subAgentInspector(agent)
                }
            } else {
                emptyState
            }
        }
        .frame(width: 430)
        .background(Theme.chrome)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Select a card")
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text("Click a session to read its transcript, or a worktree to see its git state.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session

    private func sessionInspector(_ summary: SessionSummary, status: SessionStatus, live: LiveSession?) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    StatusDot(status: status, zoom: Zoom(scale: 1.1))
                    Text(status.label)
                        .font(Theme.ui(10, .heavy))
                        .tracking(0.5)
                        .foregroundStyle(status == .busy ? Theme.busy : (status == .idle ? Theme.idle : Theme.textTertiary))
                    if let live, let name = live.name {
                        Text(name)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if let live {
                        Text("pid \(live.pid)")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                Text(summary.displayTitle)
                    .font(Theme.ui(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                FieldGrid(rows: sessionFields(summary, live: live))

                HStack(spacing: 6) {
                    ChromeButton(icon: "chevron.left.forwardslash.chevron.right", label: "Editor") {
                        store.openInEditor(summary.resolvedPath)
                    }
                    ChromeButton(icon: "doc.text.magnifyingglass") { store.revealTranscriptFile(summary) }
                    Spacer(minLength: 0)
                    ChromeButton(icon: "arrow.clockwise") { store.reloadTranscript() }
                }

                if let transcript = store.transcript, transcript.sessionId == summary.id {
                    tokenRow(transcript)
                }
            }
            .padding(14)

            Divider().overlay(Theme.hairline)

            if store.isLoadingTranscript {
                loading("Reading transcript…")
            } else if let transcript = store.transcript, transcript.sessionId == summary.id {
                TranscriptView(transcript: transcript)
            } else {
                loading("Transcript not loaded")
            }
        }
    }

    private func sessionFields(_ summary: SessionSummary, live: LiveSession?) -> [FieldGrid.Row] {
        var rows: [FieldGrid.Row] = [
            .init(label: "Folder", value: abbreviate(summary.resolvedPath), mono: true, copyable: summary.resolvedPath)
        ]
        if let branch = summary.gitBranch, !branch.isEmpty {
            rows.append(.init(label: "Branch", value: branch, mono: true, tint: Theme.branch, copyable: branch))
        }
        if let model = Format.model(summary.model) {
            rows.append(.init(label: "Model", value: model))
        }
        rows.append(.init(label: "Last active", value: Format.relative(summary.lastActivityAt) + "  ·  " + Format.absolute(summary.lastActivityAt)))
        if let started = summary.startedAt {
            rows.append(.init(label: "Started", value: Format.absolute(started)))
        }
        rows.append(.init(
            label: "Activity",
            value: "\(summary.userTurns) prompts  ·  \(summary.assistantTurns) replies  ·  \(summary.toolCalls) tool calls"
        ))
        if summary.contextTokens > 0 {
            rows.append(.init(label: "Context at last turn", value: Format.compactCount(summary.contextTokens) + " tokens"))
        }
        rows.append(.init(label: "Transcript", value: Format.bytes(summary.fileSize), mono: true))
        if let version = summary.cliVersion {
            rows.append(.init(label: "CLI", value: version, mono: true))
        }
        if let live, let entrypoint = live.entrypoint {
            rows.append(.init(label: "Entrypoint", value: [entrypoint, live.kind].compactMap { $0 }.joined(separator: " · "), mono: true))
        }
        rows.append(.init(label: "Session ID", value: summary.id, mono: true, copyable: summary.id))
        return rows
    }

    private func tokenRow(_ transcript: Transcript) -> some View {
        HStack(spacing: 14) {
            if transcript.truncated {
                Text("recent")
                    .font(Theme.ui(8.5, .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                    .help("Totals cover the most recent part of a long transcript")
            }
            StatBlock(label: "Input", value: Format.compactCount(transcript.totalInputTokens))
            StatBlock(label: "Output", value: Format.compactCount(transcript.totalOutputTokens))
            StatBlock(label: "Cache read", value: Format.compactCount(transcript.cacheReadTokens))
            if let top = transcript.toolUseCounts.max(by: { $0.value < $1.value }) {
                StatBlock(label: "Top tool", value: "\(top.key) ×\(top.value)")
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Worktree

    /// The parent node: what the workspace is and what it owns.
    private func workspaceInspector(_ workspace: Workspace) -> some View {
        ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "rectangle.3.group.fill").foregroundStyle(Theme.accent)
                    Text(workspace.name)
                        .font(Theme.ui(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(store.isOrchestratorRunning ? "running" : "idle")
                        .font(Theme.ui(10, .heavy))
                        .foregroundStyle(store.isOrchestratorRunning ? Theme.clean : Theme.textTertiary)
                }

                FieldGrid(rows: [
                    .init(label: "Branch", value: workspace.branch, mono: true, tint: Theme.branch, copyable: workspace.branch),
                    .init(label: "Cut from", value: workspace.baseRef ?? "each repo's default", mono: true),
                    .init(
                        label: "Folder",
                        value: workspace.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                        mono: true, copyable: workspace.root
                    ),
                    .init(label: "Created", value: Format.absolute(workspace.createdAt))
                ])

                HStack(spacing: 6) {
                    if store.isOrchestratorRunning {
                        ChromeButton(icon: "stop.circle", label: "Stop") { store.stopOrchestrator() }
                    } else {
                        ChromeButton(icon: "play.fill", label: "Start Claude Code") { store.startOrchestrator() }
                    }
                    ChromeButton(icon: "plus", label: "Repos") { sheet = .addRepos }
                    Spacer(minLength: 0)
                    ChromeButton(icon: "folder") { store.revealInFinder(workspace.root) }
                }

                Text("REPOSITORIES")
                    .font(Theme.ui(9.5, .heavy))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 4)
                VStack(spacing: 4) {
                    ForEach(workspace.repos) { repo in
                        Button { store.reveal(.worktree(repo.worktreePath)) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: repo.isReady ? "square.on.square" : "exclamationmark.triangle.fill")
                                    .font(Theme.ui(9))
                                    .foregroundStyle(repo.isReady ? Theme.worktree : Theme.dirty)
                                Text(repo.name).font(Theme.ui(11.5)).foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                                Text(repo.failure ?? "./\(repo.name)")
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(repo.isReady ? Theme.textTertiary : Theme.dirty)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !store.subAgents.isEmpty {
                    Text("SUB-AGENTS")
                        .font(Theme.ui(9.5, .heavy))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 4) {
                        ForEach(store.subAgents) { agent in
                            Button { store.reveal(.subAgent(agent.id)) } label: {
                                HStack(spacing: 7) {
                                    Circle()
                                        .fill(agent.state.isRunning ? Theme.busy : Theme.clean)
                                        .frame(width: 5, height: 5)
                                    Text(agent.title).font(Theme.ui(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(agent.kind).font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surface))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func subAgentInspector(_ agent: SubAgent) -> some View {
        ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(agent.state.isRunning ? Theme.busy : Theme.clean)
                        .frame(width: 7, height: 7)
                    Text(agent.title)
                        .font(Theme.ui(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                FieldGrid(rows: [
                    .init(label: "Agent type", value: agent.kind, mono: true),
                    .init(label: "State", value: agent.state.isRunning ? "running" : "finished"),
                    .init(label: "Tokens", value: agent.totalTokens.map(Format.compactCount) ?? "—"),
                    .init(label: "Handle", value: agent.agentID ?? "—", mono: true, copyable: agent.agentID)
                ])
                Text("TASK")
                    .font(Theme.ui(9.5, .heavy)).tracking(0.7).foregroundStyle(Theme.textTertiary)
                Text(agent.prompt)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let result = agent.result, !result.isEmpty {
                    Text("RESULT")
                        .font(Theme.ui(9.5, .heavy)).tracking(0.7).foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    Text(result)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private func terminalInspector(_ terminal: TerminalNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: terminal.role.icon)
                    .foregroundStyle(terminal.role == .orchestrator ? Theme.accent : Theme.worktree)
                Text(terminal.title)
                    .font(Theme.ui(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(store.terminals.isRunning(terminal.id) ? "running" : "exited")
                    .font(Theme.ui(10, .heavy))
                    .foregroundStyle(store.terminals.isRunning(terminal.id) ? Theme.clean : Theme.textTertiary)
            }
            FieldGrid(rows: [
                .init(label: "Role", value: terminal.role.label),
                .init(
                    label: "Folder",
                    value: terminal.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    mono: true, copyable: terminal.cwd
                ),
                .init(label: "Session ID", value: terminal.sessionID ?? "—", mono: true, copyable: terminal.sessionID)
            ])
            HStack(spacing: 6) {
                ChromeButton(icon: "arrow.clockwise", label: "Restart") { store.restartTerminal(terminal.id) }
                ChromeButton(icon: "chevron.left.forwardslash.chevron.right", label: "Editor") {
                    store.openInEditor(terminal.cwd)
                }
                ChromeButton(icon: "folder") { store.revealInFinder(terminal.cwd) }
                Spacer(minLength: 0)
                ChromeButton(icon: "xmark") { store.closeTerminal(terminal.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func worktreeInspector(_ worktree: Worktree, repoID: String?) -> some View {
        let sessions = attachedSessions(worktree.path)
        return ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: worktree.isMain ? "shippingbox.fill" : "square.on.square")
                        .foregroundStyle(worktree.isDirty ? Theme.dirty : Theme.worktree)
                    Text(worktree.name)
                        .font(Theme.ui(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if worktree.isMain {
                        Text("MAIN WORKTREE")
                            .font(Theme.ui(8.5, .heavy))
                            .tracking(0.6)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }

                FieldGrid(rows: worktreeFields(worktree))

                HStack(spacing: 6) {
                    ChromeButton(icon: "hammer.fill", label: "Agent") {
                        store.openTerminal(role: .repo, repoID: repoID)
                    }
                    ChromeButton(icon: "terminal", label: "Shell") {
                        store.openTerminal(role: .shell, repoID: repoID)
                    }
                    ChromeButton(icon: "chevron.left.forwardslash.chevron.right", label: "Editor") {
                        store.openInEditor(worktree.path)
                    }
                    ChromeButton(icon: "folder") { store.revealInFinder(worktree.path) }
                    Spacer(minLength: 0)
                    ChromeButton(icon: "arrow.clockwise") { store.refreshGitStatus() }
                }

                if !sessions.isEmpty {
                    Text("SESSIONS IN THIS WORKTREE")
                        .font(Theme.ui(9.5, .heavy))
                        .tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 4) {
                        ForEach(sessions, id: \.0.id) { summary, status in
                            Button {
                                store.reveal(.session(summary.id))
                            } label: {
                                HStack(spacing: 7) {
                                    StatusDot(status: status, zoom: Zoom(scale: 0.9))
                                    Text(summary.displayTitle)
                                        .font(Theme.ui(11.5))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(Format.relative(summary.lastActivityAt))
                                        .font(Theme.ui(9.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.surface)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func worktreeFields(_ worktree: Worktree) -> [FieldGrid.Row] {
        var rows: [FieldGrid.Row] = [
            .init(label: "Path", value: abbreviate(worktree.path), mono: true, copyable: worktree.path),
            .init(label: "Branch", value: worktree.branchLabel, mono: true, tint: Theme.branch, copyable: worktree.branch)
        ]
        if let head = worktree.head {
            rows.append(.init(label: "HEAD", value: String(head.prefix(10)), mono: true, copyable: head))
        }
        if worktree.hasStatus {
            let dirty = worktree.dirtyFiles ?? 0
            let untracked = worktree.untrackedFiles ?? 0
            rows.append(.init(
                label: "Working tree",
                value: dirty + untracked == 0 ? "clean" : "\(dirty) modified, \(untracked) untracked",
                tint: dirty + untracked == 0 ? Theme.clean : Theme.dirty
            ))
        } else {
            rows.append(.init(label: "Working tree", value: "checking…", tint: Theme.textTertiary))
        }
        if let upstream = worktree.upstream {
            let ahead = worktree.ahead ?? 0
            let behind = worktree.behind ?? 0
            rows.append(.init(label: "Upstream", value: "\(upstream)  ·  \(ahead) ahead, \(behind) behind", mono: true))
        }
        if let subject = worktree.lastCommitSubject {
            rows.append(.init(label: "Last commit", value: subject))
        }
        if let author = worktree.lastCommitAuthor, let date = worktree.lastCommitDate {
            rows.append(.init(label: "Committed", value: "\(author)  ·  \(Format.relative(date))"))
        }
        if worktree.isPrunable {
            rows.append(.init(label: "State", value: "prunable — the directory is gone", tint: Theme.dirty))
        }
        return rows
    }

    private func attachedSessions(_ path: String) -> [(SessionSummary, SessionStatus)] {
        store.graph.edges
            .filter { $0.to == .worktree(path) }
            .compactMap { edge in
                guard let node = store.graph.node(edge.from),
                      case .session(let summary, let status, _) = node.kind else { return nil }
                return (summary, status)
            }
            .sorted { $0.0.lastActivityAt > $1.0.lastActivityAt }
    }

    // MARK: - Helpers

    private func loading(_ message: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).font(Theme.ui(11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

/// Label/value pairs with optional click-to-copy.
struct FieldGrid: View {
    struct Row: Identifiable {
        var label: String
        var value: String
        var mono: Bool = false
        var tint: Color = Theme.textPrimary
        var copyable: String?
        var id: String { label }
    }

    var rows: [Row]
    @State private var copiedLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 120, alignment: .leading)
                    Text(copiedLabel == row.label ? "copied" : row.value)
                        .font(row.mono ? Theme.mono(10.5) : Theme.ui(11))
                        .foregroundStyle(copiedLabel == row.label ? Theme.accent : row.tint)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let copyable = row.copyable {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(copyable, forType: .string)
                            copiedLabel = row.label
                            Task {
                                try? await Task.sleep(for: .seconds(1.2))
                                if copiedLabel == row.label { copiedLabel = nil }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(Theme.ui(9))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct StatBlock: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Theme.mono(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(label.uppercased())
                .font(Theme.ui(8.5, .heavy))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
