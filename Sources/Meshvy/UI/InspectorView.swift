import SwiftUI

/// Which half of a node's files pane is showing.
enum FilesTab: String, CaseIterable, Hashable {
    case files, changes
}

/// Right panel: everything known about the selected node, plus the transcript
/// reader for sessions.
struct InspectorView: View {
    @Bindable var store: MeshvyStore
    @Binding var sheet: MeshvySheet?

    /// Kept on the panel rather than per node, so moving between agents stays
    /// on whichever half you were reading.
    @State private var filesTab: FilesTab = .files

    var body: some View {
        VStack(spacing: 0) {
            // A repository is not a node on the board — it is selected from
            // its chip on the workspace node, or its row in the sidebar — so
            // it is looked up in the workspace rather than in the graph.
            if case .worktree(let path)? = store.selection,
               let repo = store.activeWorkspace?.repos.first(where: { $0.worktreePath == path }) {
                worktreeInspector(store.worktree(for: repo), repoID: repo.id)
            } else if let selection = store.selection, let node = store.graph.node(selection) {
                switch node.kind {
                case .session(let summary, let status, let live):
                    sessionInspector(summary, status: status, live: live)
                case .terminal(let terminal):
                    terminalInspector(terminal)
                case .workspace(let workspace):
                    workspaceInspector(workspace)
                case .subAgent(let agent):
                    subAgentInspector(agent)
                case .browser(let browser):
                    browserInspector(browser)
                }
            } else {
                emptyState
            }
        }
        .frame(width: store.inspectorWidth)
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
            Text("Click a session to read its transcript, or a repository to see its git state.")
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

                let grouped = store.workspaceChanges
                if grouped.isEmpty {
                    Text("REPOSITORIES")
                        .font(Theme.ui(9.5, .heavy)).tracking(0.7)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    VStack(spacing: 4) {
                        ForEach(workspace.repos) { repo in
                            Button { store.reveal(.worktree(repo.worktreePath)) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: repo.isReady ? "square.on.square" : "exclamationmark.triangle.fill")
                                        .font(Theme.ui(9))
                                        .foregroundStyle(repo.isReady ? Theme.worktree : Theme.danger)
                                    Text(repo.name).font(Theme.ui(11.5)).foregroundStyle(Theme.textPrimary)
                                    Spacer(minLength: 0)
                                    Text(repo.failure ?? "clean")
                                        .font(Theme.mono(9.5))
                                        .foregroundStyle(repo.isReady ? Theme.textTertiary : Theme.danger)
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
                } else {
                    HStack(spacing: 6) {
                        Text("CHANGES")
                            .font(Theme.ui(9.5, .heavy)).tracking(0.7)
                            .foregroundStyle(Theme.textTertiary)
                        Text("\(store.totalChangedFiles) files across \(grouped.count) repos")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 4)

                    ForEach(grouped, id: \.repo.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Button { store.reveal(.worktree(entry.repo.worktreePath)) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "square.on.square")
                                        .font(Theme.ui(8.5)).foregroundStyle(Theme.worktree)
                                    Text(entry.repo.name)
                                        .font(Theme.ui(11, .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            ChangesList(
                                changes: entry.files,
                                selected: store.openFile?.repoPath == entry.repo.worktreePath
                                    ? store.openFile?.change : nil,
                                onSelect: { store.openDiff(repoPath: entry.repo.worktreePath, change: $0) }
                            )
                        }
                    }

                    if store.openFile != nil {
                        Divider().overlay(Theme.hairline).padding(.vertical, 4)
                        diffPane.frame(minHeight: 260)
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

    // MARK: - Browser

    /// What the page is, and what it has logged.
    ///
    /// The console is the point. A browser node on its own is a nice way to
    /// watch your app, but the reason it earns a panel is that the errors a page
    /// throws are the ones you otherwise only find by opening devtools — and an
    /// agent reads exactly this list through `browser_console`.
    private func browserInspector(_ node: BrowserNode) -> some View {
        let session = store.browsers.session(for: node.id)
        let lines = session?.console ?? []
        return ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "globe").foregroundStyle(Theme.branch)
                    Text(node.pageTitle ?? node.title)
                        .font(Theme.ui(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(session?.isLoading == true ? "loading" : (session == nil ? "idle" : "loaded"))
                        .font(Theme.ui(10, .heavy))
                        .foregroundStyle(session?.isLoading == true ? Theme.busy : Theme.textTertiary)
                }

                FieldGrid(rows: [
                    .init(label: "URL", value: node.url, mono: true, copyable: node.url),
                    .init(
                        label: "Agent handle", value: node.shortID, mono: true,
                        tint: Theme.branch, copyable: node.shortID
                    ),
                    .init(label: "Opened", value: Format.absolute(node.createdAt))
                ])

                HStack(spacing: 6) {
                    ChromeButton(icon: "arrow.clockwise", label: "Reload") { store.reloadBrowser(node.id) }
                    ChromeButton(icon: "arrow.up.forward.app", label: "Open in browser") {
                        store.openInBrowser(node.url)
                    }
                    Spacer(minLength: 0)
                    if !lines.isEmpty {
                        ChromeButton(icon: "trash") { session?.clearConsole() }
                            .help("Clear the console")
                    }
                }

                if let error = session?.loadError {
                    Text(error)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.dirty)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text("CONSOLE")
                        .font(Theme.ui(9.5, .heavy)).tracking(0.7).foregroundStyle(Theme.textTertiary)
                    Text(lines.isEmpty ? "nothing logged" : "\(lines.count) lines")
                        .font(Theme.ui(9.5)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    // Newest first: the line that matters is the one that just
                    // appeared, and this panel is read top-down.
                    ForEach(lines.reversed().prefix(200)) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.level.rawValue.uppercased())
                                .font(Theme.mono(8.5, .heavy))
                                .foregroundStyle(tint(line.level))
                                .frame(width: 34, alignment: .leading)
                            Text(line.text)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(line.level.isProblem ? Theme.textPrimary : Theme.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(line.level.isProblem ? tint(line.level).opacity(0.1) : Theme.surface)
                        )
                    }
                }
            }
            .padding(14)
        }
    }

    private func tint(_ level: ConsoleEntry.Level) -> Color {
        switch level {
        case .error: return Theme.danger
        case .warn: return Theme.dirty
        case .info: return Theme.info
        case .log: return Theme.textTertiary
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

    /// An agent's panel: what it is and what it has changed.
    ///
    /// The files are the point. A terminal node is opened in one directory and
    /// does its work there, so the question you have while watching one is what
    /// it has touched — which used to mean selecting the repository separately
    /// and remembering which agent was in it.
    private func terminalInspector(_ terminal: TerminalNode) -> some View {
        VStack(spacing: 0) {
            terminalSummary(terminal)
            Divider().overlay(Theme.hairline)
            filesPane(root: terminal.cwd, repoID: terminal.repoID)
        }
    }

    private func terminalSummary(_ terminal: TerminalNode) -> some View {
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
            if let activity = store.activity(for: terminal) {
                agentState(activity)
            }
            FieldGrid(rows: [
                .init(label: "Role", value: terminal.role.label),
                .init(
                    label: "Permission mode",
                    value: (terminal.permissionMode ?? store.permissionMode).label
                ),
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the agent is doing, as its own hooks reported it.
    private func agentState(_ activity: AgentActivity) -> some View {
        let tint: Color = switch activity.state {
        case .working: Theme.busy
        case .blocked: Theme.needsYou
        case .done: Theme.clean
        default: Theme.textTertiary
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(activity.state.label.uppercased())
                    .font(Theme.ui(9.5, .heavy))
                    .tracking(0.7)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text("\(activity.turns) turn\(activity.turns == 1 ? "" : "s") · \(activity.toolCalls) tool calls")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let line = activity.line {
                Text(line)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Reported by the session's own hooks · \(Format.relative(activity.updatedAt))")
                .font(Theme.ui(9.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.3), lineWidth: 1)
        )
    }

    private func worktreeInspector(_ worktree: Worktree, repoID: String?) -> some View {
        let files = store.changes[worktree.path] ?? []
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "square.on.square")
                        .foregroundStyle(worktree.isDirty ? Theme.dirty : Theme.worktree)
                    Text(worktree.name)
                        .font(Theme.ui(15, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text(worktree.branchLabel)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.branch)
                }

                HStack(spacing: 6) {
                    ChromeButton(icon: "hammer.fill", label: "Agent") {
                        store.openTerminal(role: .repo, repoID: repoID)
                    }
                    ChromeButton(icon: "terminal", label: "Shell") {
                        store.openTerminal(role: .shell, repoID: repoID)
                    }
                    ChromeButton(icon: "chevron.left.forwardslash.chevron.right") {
                        store.openInEditor(worktree.path)
                    }
                    ChromeButton(icon: "folder") { store.revealInFinder(worktree.path) }
                    Spacer(minLength: 0)
                    ChromeButton(icon: "arrow.clockwise") { store.refreshGitStatus() }
                }

                summary(worktree, files: files)
            }
            .padding(14)

            Divider().overlay(Theme.hairline)
            filesPane(root: worktree.path, repoID: repoID)
        }
    }

    /// One line that says what state the checkout is in, instead of a field grid.
    @ViewBuilder
    private func summary(_ worktree: Worktree, files: [FileChange]) -> some View {
        HStack(spacing: 12) {
            if files.isEmpty {
                Label("clean", systemImage: "checkmark.seal")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.clean)
            } else {
                Text("\(files.count) changed")
                    .font(Theme.ui(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("+\(files.reduce(0) { $0 + $1.additions })")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.clean)
                Text("−\(files.reduce(0) { $0 + $1.deletions })")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.danger)
            }
            if let ahead = worktree.ahead, let behind = worktree.behind, ahead + behind > 0 {
                Text("\(ahead)↑ \(behind)↓")
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
            if let subject = worktree.lastCommitSubject {
                Text(subject)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// The files pane: what a node's working directory holds, and what of it
    /// has changed.
    ///
    /// Two questions, and the changed list can only answer one of them. Before
    /// an agent has done anything there is nothing in it, which is exactly when
    /// you want to know what it is working on.
    private func filesPane(root: String, repoID: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SegmentedControl(
                    options: FilesTab.allCases,
                    selection: $filesTab,
                    label: { tab in
                        switch tab {
                        case .files: return "All files"
                        case .changes:
                            let count = changedCount(repoID: repoID)
                            return count == 0 ? "Changes" : "Changes \(count)"
                        }
                    },
                    icon: { $0 == .files ? "folder" : "plusminus" }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().overlay(Theme.hairline)

            switch filesTab {
            case .files:
                // Keyed on the folder, so moving to another node starts its
                // tree closed rather than inheriting the last one's shape.
                FilesBrowser(root: root) { store.openInEditor($0) }
                    .id(root)
            case .changes:
                changesForNode(repoID: repoID)
            }
        }
    }

    /// How many files the node's directory has changed, for the tab's own count.
    private func changedCount(repoID: String?) -> Int {
        if let repoID, let repo = store.activeWorkspace?.repos.first(where: { $0.id == repoID }) {
            return store.changes[repo.worktreePath]?.count ?? 0
        }
        return store.totalChangedFiles
    }

    /// What a node's working directory has changed, and the diff for whichever
    /// file is open.
    ///
    /// A node opened inside a repository shows that repository. One opened at
    /// the workspace root — a shell there, or an agent with no repository of
    /// its own — shows every repository beneath it, because that is what its
    /// working directory actually holds.
    @ViewBuilder
    private func changesForNode(repoID: String?) -> some View {
        if let repoID, let repo = store.activeWorkspace?.repos.first(where: { $0.id == repoID }) {
            changesSection(repoPath: repo.worktreePath, files: store.changes[repo.worktreePath] ?? [])
        } else {
            groupedChangesSection()
        }
    }

    /// Every repository under the workspace root that has changed, each under
    /// its own name, over the one diff pane they share.
    @ViewBuilder
    private func groupedChangesSection() -> some View {
        let grouped = store.workspaceChanges
        if grouped.isEmpty {
            noChanges
        } else {
            VSplit(
                top: {
                    ScrollableStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(grouped, id: \.repo.id) { entry in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button { store.reveal(.worktree(entry.repo.worktreePath)) } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "square.on.square")
                                                .font(Theme.ui(8.5)).foregroundStyle(Theme.worktree)
                                            Text(entry.repo.name)
                                                .font(Theme.ui(11, .semibold))
                                                .foregroundStyle(Theme.textSecondary)
                                            Spacer(minLength: 0)
                                            Text("\(entry.files.count)")
                                                .font(Theme.mono(9.5))
                                                .foregroundStyle(Theme.textTertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    ChangesList(
                                        changes: entry.files,
                                        selected: store.openFile?.repoPath == entry.repo.worktreePath
                                            ? store.openFile?.change : nil,
                                        onSelect: { store.openDiff(repoPath: entry.repo.worktreePath, change: $0) }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                },
                bottom: { diffPane }
            )
        }
    }

    private var noChanges: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No changes yet")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The file list, and the diff for whichever file is open.
    @ViewBuilder
    private func changesSection(repoPath: String, files: [FileChange]) -> some View {
        if files.isEmpty {
            noChanges
        } else {
            VSplit(
                top: {
                    ScrollableStack(alignment: .leading) {
                        ChangesList(
                            changes: files,
                            selected: store.openFile?.repoPath == repoPath ? store.openFile?.change : nil,
                            onSelect: { store.openDiff(repoPath: repoPath, change: $0) }
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                },
                bottom: {
                    diffPane
                }
            )
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let open = store.openFile {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(open.change.path)
                        .font(Theme.mono(10.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    Button { store.closeDiff() } label: {
                        Image(systemName: "xmark").font(Theme.ui(9, .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.surfaceSunken)

                Divider().overlay(Theme.hairline)

                if store.isLoadingDiff {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diff = store.openDiff {
                    ScrollableStack(alignment: .leading) {
                        DiffBody(diff: diff).padding(.vertical, 6)
                    }
                }
            }
        } else {
            Text("Select a file to see its diff")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
