import AgentKit
import AppKit
import BrowserKit
import FileSystemKit
import Foundation
import MeshvyModels

// Terminals, the agent bridge, hook-driven status, and retuning a running session.
extension MeshvyStore {
    // MARK: - Terminals

    // MARK: - Agent bridge
    //
    // Claude's Agent tool runs sub-agents in-process, so they have no terminal
    // to show. Instead the orchestrator is told to delegate with the `meshvy`
    // helper, which drops a request here and gets a real agent back — its own
    // process, its own PTY, its own node on the canvas.

    func startBridge(for workspace: Workspace) {
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
    func drainBridge() {
        guard let workspace = activeWorkspace else { return }
        for (url, request) in AgentBridge.pendingRequests(for: workspace) {
            // Remove first: a request that throws must not be retried forever.
            try? FileManager.default.removeItem(at: url)
            switch request.kind {
            case "spawn": handleSpawn(request, in: workspace)
            case "send": handleSend(request)
            default: continue
            }
        }
    }

    func handleSpawn(_ request: AgentBridge.Request, in workspace: Workspace) {
        guard let repoName = request.repo,
              let repo = workspace.repos.first(where: { $0.name == repoName }) else {
            show(.init(kind: .failure, title: "Agent asked for an unknown repo", detail: request.repo))
            return
        }
        guard let node = openTerminal(
            role: .repo,
            repoID: repo.id,
            openingTask: request.task,
            bridgeID: request.id
        ) else { return }

        AgentBridge.record(
            .init(
                id: request.id,
                sessionId: node.sessionID,
                repo: repo.name,
                cwd: node.cwd,
                transcriptHint: node.sessionID,
                startedAt: Date().timeIntervalSince1970
            ),
            in: workspace
        )
        show(.init(
            kind: .success,
            title: "Orchestrator started an agent in \(repo.name)",
            detail: request.task
        ))
    }

    // MARK: - Agent status
    //
    // Every session Meshvy starts is handed a settings file whose hooks report
    // what the agent is doing. Nothing here parses terminal output.

    /// Applies everything the hooks have reported since the last pass.
    func drainHooks() {
        guard let workspace = activeWorkspace else { return }
        let before = activity
        checkStartupPrompts()
        for event in AgentHooks.drain(for: workspace) { apply(event) }
        guard activity != before else { return }

        notifier.badge(agentsNeedingYou.count)
        statusLine = summaryLine()
        AgentBridge.publishStatus(statusRows(), in: workspace)
    }

    /// What every agent is doing, in the shape `meshvy status` prints.
    func statusRows() -> [AgentBridge.StatusRow] {
        guard let workspace = activeWorkspace else { return [] }
        return workspace.allTerminals.compactMap { node in
            guard let record = activity(for: node) else { return nil }
            return AgentBridge.StatusRow(
                id: node.bridgeID,
                title: node.title,
                repo: workspace.repos.first { $0.id == node.repoID }?.name,
                state: record.state.rawValue,
                line: record.line
            )
        }
    }

    func apply(_ event: AgentHooks.Event) {
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

        guard previous != record.state,
              let node = terminalNode(forSession: event.sessionID) else { return }
        announce(record, node: node)
    }

    /// A question appearing, or a turn ending, is the moment worth a nudge —
    /// and only if you are not already looking at that node.
    func announce(_ record: AgentActivity, node: TerminalNode) {
        let worthTelling = record.state == .blocked || record.state == .done
        let id = canvasID(for: node)
        guard worthTelling, selection != id else { return }
        unread.insert(node.id)

        guard !NSApp.isActive else { return }
        notifier.post(
            title: record.state == .blocked
                ? "\(node.title) needs you"
                : "\(node.title) finished",
            body: record.message,
            node: id
        )
    }

    /// Flags an agent stopped on a dialog that runs before its session exists,
    /// which no hook can report. Only ever fills a gap: a session that has
    /// reported once is left to its hooks forever.
    func checkStartupPrompts() {
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

    func terminalNode(forSession sessionID: String) -> TerminalNode? {
        guard let workspace = activeWorkspace else { return nil }
        return workspace.allTerminals.first { $0.sessionID == sessionID }
    }

    /// The orchestrator is hosted by the workspace node rather than having a
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

    // MARK: - The hover guard
    //
    // The wheel pans the canvas, which is right almost everywhere — but it also
    // means a terminal can never be scrolled back through, and a page can never
    // be scrolled down. Resting the pointer on one hands it the wheel until the
    // pointer leaves. Terminals and browsers share this, since node ids are
    // unique across both.

    public func hoverTerminal(_ id: UUID?) {
        guard hoveredTerminal != id else { return }
        hoveredTerminal = id
        armTask?.cancel()
        armedTerminal = nil
        guard let id else { return }
        armTask = Task { [weak self] in
            try? await Task.sleep(for: MeshvyStore.armDelay)
            guard !Task.isCancelled else { return }
            guard let self, self.hoveredTerminal == id else { return }
            self.armedTerminal = id
        }
    }

    /// Agents stopped on something only you can answer.
    public var agentsNeedingYou: [TerminalNode] {
        (activeWorkspace?.allTerminals ?? []).filter { activity(for: $0)?.state == .blocked }
    }

    /// Jumps to the next agent waiting on you, cycling through them if there
    /// are several. The one shortcut worth having on a busy board.
    public func revealNextNeedingYou() {
        let ids = agentsNeedingYou.map { canvasID(for: $0) }
        guard !ids.isEmpty else {
            show(.init(kind: .info, title: "No agent is waiting on you", detail: nil))
            return
        }
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { ids.index(after: $0) % ids.count } ?? 0
        reveal(ids[next])
    }

    func markRead(_ id: NodeID?) {
        let terminalID: UUID?
        switch id {
        case .terminal(let value): terminalID = value
        case .workspace: terminalID = activeWorkspace?.orchestrator?.id
        default: terminalID = nil
        }
        guard let terminalID, unread.remove(terminalID) != nil else { return }
        notifier.badge(agentsNeedingYou.count)
    }

    /// One agent typing into another's terminal.
    func handleSend(_ request: AgentBridge.Request) {
        guard let target = request.to, let message = request.message,
              let workspace = activeWorkspace else { return }
        let node = workspace.terminals.first { $0.bridgeID == target }
            ?? (workspace.orchestrator?.bridgeID == target ? workspace.orchestrator : nil)
        guard let node, let session = terminals.session(for: node.id) else { return }
        session.send(message + "\r")
    }

    /// Starts Claude Code on the workspace node itself. Its working directory
    /// is the workspace root, so every repository is a subdirectory it can see.
    public func startOrchestrator() {
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
        terminals.start(
            node: node,
            command: AgentCommand.orchestrator(
                workspace: workspace, sessionID: sessionID, name: name, options: options
            ),
            // Puts `meshvy` on the orchestrator's PATH so it can delegate.
            environment: ["PATH": workspace.binDirectory + ":" + currentPath()]
        )
        workspace.orchestrator = node
        update(workspace)
        startBridge(for: workspace)
        selection = .workspace(workspace.id)
        refreshSubAgents()
    }

    public func stopOrchestrator() {
        guard var workspace = activeWorkspace, let node = workspace.orchestrator else { return }
        terminals.discard(node.id)
        unread.remove(node.id)
        if let sessionID = node.sessionID { activity[sessionID] = nil }
        workspace.orchestrator = nil
        subAgents = []
        update(workspace)
        notifier.badge(agentsNeedingYou.count)
    }

    public var isOrchestratorRunning: Bool {
        guard let node = activeWorkspace?.orchestrator else { return false }
        return terminals.isRunning(node.id)
    }

    /// What every session Meshvy starts is launched with. One place, so the
    /// orchestrator and the agents it spawns can never drift apart.
    func agentOptions(for workspace: Workspace) -> AgentCommand.Options {
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
    func send(_ command: String, to node: TerminalNode, saying what: String) -> Bool {
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
    func updateTerminal(_ id: UUID, _ edit: (inout TerminalNode) -> Void) {
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

    /// Opens a terminal for one repository, or a plain shell.
    @discardableResult
    public func openTerminal(
        role: TerminalNode.Role,
        repoID: String? = nil,
        openingTask: String? = nil,
        bridgeID: String? = nil
    ) -> TerminalNode? {
        guard var workspace = activeWorkspace else { return nil }
        guard role != .orchestrator else { startOrchestrator(); return workspace.orchestrator }

        let repo = repoID.flatMap { id in workspace.repos.first { $0.id == id } }
        let cwd = repo?.worktreePath ?? workspace.root
        guard FileManager.default.fileExists(atPath: cwd) else {
            show(.init(kind: .failure, title: "That folder does not exist yet", detail: cwd))
            return nil
        }

        let sessionID = role == .shell ? nil : UUID().uuidString.lowercased()
        let name = AgentCommand.derivedName(role: role, context: repo?.name ?? workspace.name)
        var node = TerminalNode(
            role: role,
            title: openingTask.map { String($0.prefix(48)) }
                ?? (role == .shell ? (repo?.name ?? workspace.name) : name),
            cwd: cwd,
            repoID: repo?.id,
            sessionID: sessionID
        )
        node.size = CGSize(width: 580, height: 340)
        node.bridgeID = bridgeID
        node.openingTask = openingTask
        node.permissionMode = permissionMode
        node.model = models.selectedModelID
        node.effort = agentEffort

        let command: [String]
        if role == .shell {
            command = []
        } else {
            guard let repo else { return nil }
            command = AgentCommand.repoAgent(
                workspace: workspace, repo: repo, sessionID: sessionID!, name: name,
                task: openingTask,
                options: agentOptions(for: workspace)
            )
        }

        terminals.start(node: node, command: command)
        workspace.terminals.append(node)
        update(workspace)
        selection = .terminal(node.id)
        reveal(.terminal(node.id))
        return node
    }
}
