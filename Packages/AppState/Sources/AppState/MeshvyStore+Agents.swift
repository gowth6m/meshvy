import AgentKit
import AppKit
import BrowserKit
import FileSystemKit
import Foundation
import MeshvyModels
import TerminalKit

// Terminals, the agent bridge, hook-driven status, and retuning a running session.
//
// A workspace works the way a project does in Claude Code. The coordinator is
// its one main chat: you type requests there, it starts a thread for each piece
// of work, sends follow-ups to the thread that owns it, and reports back
// briefly. A thread is one piece of work with its own agent and terminal; when
// it finishes a turn or needs you, Meshvy tells the coordinator.
extension MeshvyStore {
    // MARK: - Agent bridge
    //
    // Claude's Agent tool runs sub-agents in-process, so they have no terminal
    // to show. Instead the coordinator starts threads with the `meshvy` helper,
    // which drops a request here and gets a real agent back — its own process,
    // its own PTY, its own node on the canvas.

    public func startBridge(for workspace: Workspace) {
        AgentBridge.install(for: workspace)
        AgentHooks.install(for: workspace)
        BrowserBridge.install(for: workspace)
        BrowserBridge.sweepStaleResponses(for: workspace)
        bridgeWatcher = DirectoryWatcher(
            paths: [workspace.requestsDirectory],
            debounce: 0.2
        ) { [weak self] in
            Task { @MainActor in self?.drainBridge() }
        }
        // Status should feel immediate — a badge that lags a second behind the
        // agent is worse than no badge.
        hookWatcher = DirectoryWatcher(
            paths: [AgentHooks.eventsDirectory(for: workspace)],
            debounce: 0.1
        ) { [weak self] in
            Task { @MainActor in self?.drainHooks() }
        }
        // A tool call is a question an agent is sitting and waiting on, so this
        // one is as close to immediate as FSEvents will give.
        browserWatcher = DirectoryWatcher(
            paths: [BrowserBridge.requestsDirectory(for: workspace)],
            debounce: 0.05
        ) { [weak self] in
            Task { @MainActor in self?.drainBrowserBridge() }
        }
        drainBridge()
        drainBrowserBridge()
    }

    /// Handles everything the helper has asked for since the last pass.
    public func drainBridge() {
        guard let workspace = activeWorkspace else { return }
        for (url, request) in AgentBridge.pendingRequests(for: workspace) {
            // Remove first: a request that throws must not be retried forever.
            try? FileManager.default.removeItem(at: url)
            switch request.kind {
            case "thread", "spawn": handleThreadRequest(request, in: workspace)
            case "send": handleSend(request)
            case "resolve": handleResolve(request)
            default: continue
            }
        }
    }

    /// The coordinator starting a thread.
    public func handleThreadRequest(_ request: AgentBridge.Request, in workspace: Workspace) {
        var repo: WorkspaceRepo?
        if let repoName = request.repo, !repoName.isEmpty {
            repo = workspace.repos.first { $0.name == repoName }
            guard repo != nil else {
                show(.init(kind: .failure, title: "The coordinator asked for an unknown repo", detail: repoName))
                return
            }
        }
        guard let node = openTerminal(
            role: .repo,
            repoID: repo?.id,
            title: request.title,
            openingTask: request.task,
            bridgeID: request.id,
            // The coordinator is mid-turn, very likely with you watching it; a
            // new thread is news, not a reason to take the board away from it.
            reveal: false
        ) else { return }

        show(.init(
            kind: .success,
            title: "New thread: \(node.title)",
            detail: repo.map { "in \($0.name)" },
            action: ("Show", { [weak self] in self?.reveal(.terminal(node.id)) })
        ))
    }

    /// Writes what `meshvy` needs to find a thread again: its session, so
    /// `wait` and `context` can read its transcript.
    func recordThread(_ node: TerminalNode, repo: WorkspaceRepo?, in workspace: Workspace) {
        guard let bridgeID = node.bridgeID else { return }
        AgentBridge.record(
            .init(
                id: bridgeID,
                title: node.title,
                sessionId: node.sessionID,
                repo: repo?.name,
                cwd: node.cwd,
                transcriptHint: node.sessionID,
                startedAt: Date().timeIntervalSince1970
            ),
            in: workspace
        )
    }

    // MARK: - Threads

    /// What a thread is called until its first message names it.
    public static let untitledThread = "New thread"

    /// Where one thread stands. See `ThreadState`.
    public func threadState(for node: TerminalNode) -> ThreadState {
        ThreadState.of(
            activity: activity(for: node),
            isRunning: terminals.isRunning(node.id),
            isResolved: node.isResolved
        )
    }

    /// Threads still part of the work in hand, whatever wants you first.
    public var openThreads: [TerminalNode] {
        (activeWorkspace?.threads ?? [])
            .filter { !$0.isResolved }
            .map { ($0, threadState(for: $0).rank) }
            .sorted { $0.1 == $1.1 ? $0.0.createdAt > $1.0.createdAt : $0.1 < $1.1 }
            .map(\.0)
    }

    /// Threads put away, most recent first.
    public var resolvedThreads: [TerminalNode] {
        (activeWorkspace?.threads ?? [])
            .filter(\.isResolved)
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    /// Plain shells — not threads, and not part of the coordinator's work.
    public var shells: [TerminalNode] {
        (activeWorkspace?.terminals ?? []).filter { $0.role == .shell }
    }

    /// Starts an empty thread at the workspace root, for work you want to
    /// drive yourself rather than through the coordinator.
    @discardableResult
    public func newThread(repoID: String? = nil) -> TerminalNode? {
        openTerminal(role: .repo, repoID: repoID)
    }

    /// Puts a finished thread away. Nothing is stopped and nothing leaves the
    /// board; it only leaves the list of open threads.
    public func resolveThread(_ id: UUID) {
        updateTerminal(id) { $0.resolvedAt = Date() }
        unread.remove(id)
        notifier.badge(agentsNeedingYou.count)
        publishStatus()
    }

    public func reopenThread(_ id: UUID) {
        updateTerminal(id) { $0.resolvedAt = nil }
        publishStatus()
    }

    func handleResolve(_ request: AgentBridge.Request) {
        guard let target = request.to,
              let node = activeWorkspace?.terminals.first(where: { $0.bridgeID == target }) else { return }
        resolveThread(node.id)
    }

    /// Tells the coordinator a thread has something to say, so it can relay
    /// it to you without ever having had to sit and wait on the thread.
    ///
    /// Typed into the coordinator's terminal as one line, the way `meshvy
    /// send` types into a thread. Claude Code queues what is typed mid-turn,
    /// so a coordinator in the middle of something reads it when it is done.
    func reportToCoordinator(_ node: TerminalNode, state: ThreadState, message: String?) {
        guard node.isThread, let id = node.bridgeID,
              let coordinator = activeWorkspace?.orchestrator,
              let session = terminals.session(for: coordinator.id), session.isRunning
        else { return }
        session.send(AgentBridge.report(id: id, title: node.title, state: state, message: message) + "\r")
    }

    // MARK: - Agent status
    //
    // Every session Meshvy starts is handed a settings file whose hooks report
    // what the agent is doing. Nothing here parses terminal output.

    /// Applies everything the hooks have reported since the last pass.
    public func drainHooks() {
        guard let workspace = activeWorkspace else { return }
        let before = activity
        checkStartupPrompts()
        for event in AgentHooks.drain(for: workspace) { apply(event) }
        guard activity != before else { return }

        notifier.badge(agentsNeedingYou.count)
        statusLine = summaryLine()
        AgentBridge.publishStatus(statusRows(), in: workspace)
    }

    func publishStatus() {
        guard let workspace = activeWorkspace else { return }
        AgentBridge.publishStatus(statusRows(), in: workspace)
    }

    /// Every thread and where it stands, in the shape `meshvy threads` prints.
    public func statusRows() -> [AgentBridge.StatusRow] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.threads.map { node in
            AgentBridge.StatusRow(
                id: node.bridgeID,
                title: node.title,
                repo: workspace.repos.first { $0.id == node.repoID }?.name,
                state: threadState(for: node).label.lowercased(),
                line: node.isResolved ? nil : activity(for: node)?.line
            )
        }
    }

    public func apply(_ event: AgentHooks.Event) {
        var record = activity[event.sessionID] ?? AgentActivity(sessionID: event.sessionID)
        let previous = record.state

        record.state = event.state
        record.updatedAt = event.at
        if event.startsTurn { record.turns += 1 }
        if event.startsTool { record.toolCalls += 1 }
        switch event.state {
        case .working:
            // A turn starting clears the previous turn's tool and reply.
            if event.startsTurn { record.tool = nil; record.detail = nil }
            if event.startsTool { record.tool = event.tool; record.detail = event.detail }
            record.message = nil
        case .blocked, .done:
            record.message = event.message
            record.tool = nil
            record.detail = nil
        case .waiting, .ended:
            record.tool = nil
            record.detail = nil
            record.message = event.message
        }
        activity[event.sessionID] = record

        guard var node = terminalNode(forSession: event.sessionID) else { return }
        // Writing to a resolved thread — you, or the coordinator — reopens
        // it, the way a reply reopens a resolved thread anywhere else.
        if event.startsTurn, node.isResolved {
            reopenThread(node.id)
            node.resolvedAt = nil
        }
        // A thread you started by hand is named by the first thing you ask it,
        // the way a new conversation anywhere else takes its title.
        if event.startsTurn, node.isThread, node.title == MeshvyStore.untitledThread,
           let prompt = event.prompt, !prompt.isEmpty, !prompt.hasPrefix("/") {
            let title = String(prompt.prefix(48))
            updateTerminal(node.id) { $0.title = title }
            node.title = title
            if let workspace = activeWorkspace {
                recordThread(node, repo: workspace.repos.first { $0.id == node.repoID }, in: workspace)
            }
        }
        guard previous != record.state else { return }
        announce(record, node: node)
        if record.state == .done || record.state == .blocked {
            reportToCoordinator(node, state: threadState(for: node), message: record.message)
        }
    }

    /// A question appearing, or a turn ending, is the moment worth a nudge —
    /// and only if you are not already looking at that node.
    public func announce(_ record: AgentActivity, node: TerminalNode) {
        let worthTelling = record.state == .blocked || record.state == .done
        let id = canvasID(for: node)
        guard worthTelling, selection != id else { return }
        unread.insert(node.id)

        guard !NSApp.isActive else { return }
        notifier.post(
            title: record.state == .blocked
                ? "\(node.title) needs you"
                : (node.isThread ? "\(node.title) is ready" : "\(node.title) finished"),
            body: record.message,
            node: id
        )
    }

    /// Flags an agent stopped on a dialog that runs before its session exists,
    /// which no hook can report. Only ever fills a gap: a session that has
    /// reported once is left to its hooks forever.
    public func checkStartupPrompts() {
        guard let workspace = activeWorkspace else { return }
        for node in workspace.allTerminals {
            guard let sessionID = node.sessionID,
                  activity[sessionID] == nil,
                  let session = terminals.session(for: node.id), session.isRunning,
                  let message = AgentHooks.startupPrompt(onScreen: session.screenText)
            else { continue }
            var record = AgentActivity(sessionID: sessionID)
            record.state = .blocked
            record.message = message
            activity[sessionID] = record
            announce(record, node: node)
        }
    }

    public func terminalNode(forSession sessionID: String) -> TerminalNode? {
        guard let workspace = activeWorkspace else { return nil }
        return workspace.allTerminals.first { $0.sessionID == sessionID }
    }

    /// The coordinator is hosted by the workspace node rather than having a
    /// card of its own, so a terminal does not always map to `.terminal`.
    public func canvasID(for node: TerminalNode) -> NodeID {
        if let workspace = activeWorkspace, workspace.orchestrator?.id == node.id {
            return .workspace(workspace.id)
        }
        return .terminal(node.id)
    }

    /// Current state of one terminal. Terminals with no agent in them — and
    /// agents that have exited — report nothing.
    public func activity(for node: TerminalNode) -> AgentActivity? {
        guard let sessionID = node.sessionID else { return nil }
        guard terminals.isRunning(node.id) else { return nil }
        return activity[sessionID]
    }

    public func isUnread(_ id: UUID) -> Bool { unread.contains(id) }

    /// Agents stopped on something only you can answer.
    public var agentsNeedingYou: [TerminalNode] {
        (activeWorkspace?.allTerminals ?? []).filter { activity(for: $0)?.state == .blocked }
    }

    /// Jumps to the next agent waiting on you, cycling through them if there
    /// are several. The one shortcut worth having on a busy board.
    public func revealNextNeedingYou() {
        let ids = agentsNeedingYou.map { canvasID(for: $0) }
        guard !ids.isEmpty else {
            show(.init(kind: .info, title: "Nothing is waiting on you", detail: nil))
            return
        }
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { ids.index(after: $0) % ids.count } ?? 0
        reveal(ids[next])
    }

    public func markRead(_ id: NodeID?) {
        let terminalID: UUID?
        switch id {
        case .terminal(let value): terminalID = value
        case .workspace: terminalID = activeWorkspace?.orchestrator?.id
        default: terminalID = nil
        }
        guard let terminalID, unread.remove(terminalID) != nil else { return }
        notifier.badge(agentsNeedingYou.count)
    }

    /// The coordinator, or a thread, typing a follow-up into another thread.
    public func handleSend(_ request: AgentBridge.Request) {
        guard let target = request.to, let message = request.message,
              let workspace = activeWorkspace else { return }
        let node = workspace.terminals.first { $0.bridgeID == target }
            ?? (workspace.orchestrator?.bridgeID == target ? workspace.orchestrator : nil)
        guard let node, let session = terminals.session(for: node.id) else { return }
        if node.isResolved { reopenThread(node.id) }
        session.send(message + "\r")
    }

    /// Starts the coordinator on the workspace node itself. Its working
    /// directory is the workspace root, so every repository is a subdirectory
    /// it can see.
    public func startCoordinator() {
        guard var workspace = activeWorkspace else { return }
        if let existing = workspace.orchestrator, terminals.isRunning(existing.id) {
            reveal(.workspace(workspace.id))
            return
        }
        guard FileManager.default.fileExists(atPath: workspace.root) else {
            show(.init(kind: .failure, title: "Workspace folder is missing", detail: workspace.root))
            return
        }

        let sessionID = UUID().uuidString.lowercased()
        let name = AgentCommand.derivedName(role: .orchestrator, context: workspace.name)
        var node = TerminalNode(
            role: .orchestrator,
            title: name,
            cwd: workspace.root,
            sessionID: sessionID
        )
        node.size = CGSize(width: workspace.boardWidth, height: workspace.boardHeight)
        node.permissionMode = permissionMode
        node.model = models.selectedModelID
        node.effort = agentEffort

        AgentBridge.install(for: workspace)
        BrowserBridge.install(for: workspace)
        let options = agentOptions(for: workspace)
        let session = terminals.start(
            node: node,
            command: AgentCommand.coordinator(
                workspace: workspace, sessionID: sessionID, name: name, options: options
            ),
            // Puts `meshvy` on the coordinator's PATH so it can start threads.
            environment: ["PATH": workspace.binDirectory + ":" + currentPath()]
        )
        watchExit(of: node, session: session)
        workspace.orchestrator = node
        update(workspace)
        startBridge(for: workspace)
        selection = .workspace(workspace.id)
        refreshSubAgents()
    }

    public func stopCoordinator() {
        guard var workspace = activeWorkspace, let node = workspace.orchestrator else { return }
        terminals.discard(node.id)
        unread.remove(node.id)
        if let sessionID = node.sessionID { activity[sessionID] = nil }
        workspace.orchestrator = nil
        subAgents = []
        update(workspace)
        notifier.badge(agentsNeedingYou.count)
    }

    public var isCoordinatorRunning: Bool {
        guard let node = activeWorkspace?.orchestrator else { return false }
        return terminals.isRunning(node.id)
    }

    /// What every session Meshvy starts is launched with. One place, so the
    /// coordinator and its threads can never drift apart.
    public func agentOptions(for workspace: Workspace) -> AgentCommand.Options {
        AgentCommand.Options(
            model: models.selectedModelID,
            permissionMode: permissionMode,
            effort: agentEffort,
            settingsPath: AgentHooks.settingsPath(for: workspace),
            mcpConfigPath: BrowserBridge.configPath(for: workspace)
        )
    }

    // MARK: - Retuning a session
    //
    // All three settings are chosen per board and remembered for the next
    // agent. Two of them can also be changed inside a session that is already
    // running, because the CLI has a command for them; the permission mode
    // cannot, so that one says so rather than pretending.

    /// Model for the next agent, and for this one if it is still running.
    public func selectModel(_ id: String?, applyingTo node: TerminalNode? = nil) {
        models.selectedModelID = id
        persistLayout()
        guard let node else { return }
        guard let id else {
            show(.init(
                kind: .info,
                title: "New agents will use the CLI's own model",
                detail: "A running session keeps the model it started with."
            ))
            return
        }
        // Recorded on the node only if the session took it, so a card never
        // claims a model its agent is not on.
        if send("/model \(id)", to: node, saying: "switch to \(models.displayName(for: id))") {
            updateTerminal(node.id) { $0.model = id }
        }
    }

    /// Effort for the next agent, and for this one if it is still running.
    public func selectEffort(_ effort: AgentEffort, applyingTo node: TerminalNode? = nil) {
        agentEffort = effort
        guard let node else { return }
        guard let level = effort.flag else {
            show(.init(
                kind: .info,
                title: "New agents will use the CLI's own effort level",
                detail: "A running session keeps the level it started with."
            ))
            return
        }
        if send("/effort \(level)", to: node, saying: "think with \(effort.label.lowercased()) effort") {
            updateTerminal(node.id) { $0.effort = effort }
        }
    }

    /// Permission mode for the next agent. A running session's mode is not
    /// something the CLI exposes, so this says how to change it instead of
    /// quietly doing nothing.
    public func selectPermissionMode(_ mode: PermissionMode, notifyingAbout node: TerminalNode? = nil) {
        permissionMode = mode
        guard let node, terminals.isRunning(node.id) else { return }
        show(.init(
            kind: .info,
            title: "New agents will start in “\(mode.label)”",
            detail: "⇧⇥ cycles the mode inside \(node.title), or restart it to launch in this one."
        ))
    }

    /// Types a slash command into a running session, the way you would yourself.
    ///
    /// Returns false when there was no session to type into. An agent that is
    /// mid-turn still takes it — Claude Code queues what you type and runs it
    /// when the turn ends — but that is worth saying rather than leaving you to
    /// wonder why nothing changed.
    @discardableResult
    public func send(_ command: String, to node: TerminalNode, saying what: String) -> Bool {
        guard let session = terminals.session(for: node.id), session.isRunning else { return false }
        session.send(command + "\r")
        let isBusy = activity(for: node)?.state == .working
        show(.init(
            kind: .info,
            title: "Asked \(node.title) to \(what)",
            detail: isBusy ? "It is mid-turn, so this runs when the turn ends." : nil
        ))
        return true
    }

    /// Edits one terminal in place, wherever it lives on the workspace.
    public func updateTerminal(_ id: UUID, _ edit: (inout TerminalNode) -> Void) {
        guard var workspace = activeWorkspace else { return }
        if var node = workspace.orchestrator, node.id == id {
            edit(&node)
            workspace.orchestrator = node
        } else if let index = workspace.terminals.firstIndex(where: { $0.id == id }) {
            edit(&workspace.terminals[index])
        } else {
            return
        }
        update(workspace)
    }

    func currentPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Opens a thread or a plain shell, in one repository or at the workspace
    /// root.
    @discardableResult
    public func openTerminal(
        role: TerminalNode.Role,
        repoID: String? = nil,
        title: String? = nil,
        openingTask: String? = nil,
        bridgeID: String? = nil,
        reveal shouldReveal: Bool = true
    ) -> TerminalNode? {
        guard var workspace = activeWorkspace else { return nil }
        guard role != .orchestrator else { startCoordinator(); return workspace.orchestrator }

        let repo = repoID.flatMap { id in workspace.repos.first { $0.id == id } }
        let cwd = repo?.worktreePath ?? workspace.root
        guard FileManager.default.fileExists(atPath: cwd) else {
            show(.init(kind: .failure, title: "That folder does not exist yet", detail: cwd))
            return nil
        }

        let sessionID = role == .shell ? nil : UUID().uuidString.lowercased()
        let name = AgentCommand.derivedName(role: role, context: repo?.name ?? workspace.name)
        let threadTitle = title.map { String($0.prefix(60)) }
            ?? openingTask.map { String($0.prefix(48)) }
            ?? MeshvyStore.untitledThread
        var node = TerminalNode(
            role: role,
            title: role == .shell ? (repo?.name ?? workspace.name) : threadTitle,
            cwd: cwd,
            repoID: repo?.id,
            sessionID: sessionID
        )
        node.size = CGSize(width: 580, height: 340)
        // Every thread can be addressed, whoever started it: the coordinator
        // hears about all of them, and has to be able to answer.
        node.bridgeID = role == .shell ? nil : (bridgeID ?? AgentBridge.newID())
        node.openingTask = openingTask
        node.permissionMode = permissionMode
        node.model = models.selectedModelID
        node.effort = agentEffort

        let command: [String]
        var environment: [String: String] = [:]
        if role == .shell {
            command = []
        } else {
            AgentBridge.install(for: workspace)
            command = AgentCommand.thread(
                workspace: workspace, repo: repo, sessionID: sessionID!, name: name,
                title: node.title,
                task: openingTask,
                options: agentOptions(for: workspace)
            )
            // A thread can read its siblings' work with `meshvy context`.
            environment["PATH"] = workspace.binDirectory + ":" + currentPath()
        }

        watchExit(of: node, session: terminals.start(node: node, command: command, environment: environment))
        workspace.terminals.append(node)
        update(workspace)
        if role != .shell { recordThread(node, repo: repo, in: workspace) }
        publishStatus()
        if shouldReveal {
            selection = .terminal(node.id)
            reveal(.terminal(node.id))
        }
        return node
    }

    /// Hears about a terminal's process ending, which nothing else announces.
    /// An agent that exits fires no hook to say so, and a session's
    /// `isRunning` is not observed — so a dead terminal went on being drawn as
    /// a live one until something unrelated happened to redraw the board.
    func watchExit(of node: TerminalNode, session: TerminalSession) {
        let started = Date()
        session.onExit = { [weak self] code in
            self?.terminalExited(node, code: code, after: Date().timeIntervalSince(started))
        }
    }

    func terminalExited(_ node: TerminalNode, code: Int32?, after seconds: TimeInterval) {
        // Closed or restarted from here: the node is gone, and so is the news.
        guard activeWorkspace?.allTerminals.contains(where: { $0.id == node.id }) ?? false else { return }
        rebuild()
        statusLine = summaryLine()
        notifier.badge(agentsNeedingYou.count)

        // An agent gone within seconds of starting never got going — most
        // often because `claude` is not on the PATH a login shell sees. The
        // coordinator's node folds back to its start prompt the moment its
        // process ends, taking whatever the shell printed with it, so the
        // reason is kept on a banner instead of vanishing with the terminal.
        guard node.sessionID != nil, let code, code != 0, seconds < 15 else { return }
        // 127 is the shell failing to find `claude` — as definite an answer
        // as asking for it, so every Start prompt can say so too.
        if code == 127 { claudeInstalled = false }
        let lastLines = (terminals.session(for: node.id)?.screenText ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: "\n")
        show(.init(
            kind: .failure,
            title: code == 127
                ? "Claude Code is not installed, or not on your PATH"
                : "\(node.title) exited as it started (exit \(code))",
            detail: lastLines.isEmpty ? nil : lastLines,
            action: code == 127 ? ("Get Claude Code", { [weak self] in self?.openClaudeCodeInstallPage() }) : nil
        ))
    }

    /// Where the `claude` CLI comes from. Meshvy drives it and does not ship it.
    public func openClaudeCodeInstallPage() {
        if let url = URL(string: "https://claude.com/claude-code") { NSWorkspace.shared.open(url) }
    }

    /// Asks the login shell whether `claude` is on its PATH, off the main
    /// thread — a login shell can take a moment to read its profile.
    public func checkClaudeInstalled() {
        Task.detached(priority: .utility) {
            let installed = AgentCommand.isInstalled()
            await MainActor.run { [weak self] in self?.claudeInstalled = installed }
        }
    }

    /// While the answer is no, asks again whenever Meshvy comes back to the
    /// front — which is what happens after installing it in Terminal — so the
    /// warning goes away without a relaunch.
    func recheckClaudeOnActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.claudeInstalled == false else { return }
                self.checkClaudeInstalled()
            }
        }
    }
}
