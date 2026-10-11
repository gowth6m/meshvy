import Foundation

/// Builds the `claude` invocation a terminal node runs.
///
/// Meshvy does not host the agent. It starts the real CLI inside a PTY with a
/// pre-assigned session id, so the agent registers itself in
/// `~/.claude/sessions` and the board can match its transcript to the terminal
/// it is running in.
enum AgentCommand {
    /// Resolved once; `claude` is usually a Homebrew or local-bin shim.
    static let claudePath: String = {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // The terminal runs under a login shell, so a bare name resolves from PATH.
        return "claude"
    }()

    struct Options {
        var model: String? = ModelDefaults.modelID
        var permissionMode: PermissionMode = .acceptEdits
        /// Settings file holding the status hooks — see `AgentHooks`. An
        /// additional source, so the user's own settings still apply.
        var settingsPath: String?
    }

    /// Argv for an orchestrator sitting at the workspace root, with every
    /// repository as a subdirectory beneath it.
    static func orchestrator(
        workspace: Workspace,
        sessionID: String,
        name: String,
        options: Options = Options()
    ) -> [String] {
        base(sessionID: sessionID, name: name, options: options)
            + ["--append-system-prompt", orchestratorBrief(workspace: workspace)]
    }

    /// Argv for an agent working in one repository of the workspace.
    static func repoAgent(
        workspace: Workspace,
        repo: WorkspaceRepo,
        sessionID: String,
        name: String,
        task: String? = nil,
        options: Options = Options()
    ) -> [String] {
        var arguments = base(sessionID: sessionID, name: name, options: options)
            + ["--append-system-prompt", repoBrief(workspace: workspace, repo: repo)]
        // An agent the orchestrator spawned starts working immediately; the
        // task is its opening message, so the terminal shows it being answered.
        if let task, !task.isEmpty { arguments.append(task) }
        return arguments
    }

    /// Delegation runs through the `meshvy` helper, so that one command is
    /// pre-approved. `acceptEdits` does not cover Bash, and an orchestrator
    /// that stops to ask permission for every spawn never gets going.
    static let allowedDelegationTools = "Bash(meshvy:*)"

    private static func base(sessionID: String, name: String, options: Options) -> [String] {
        var arguments = [claudePath, "--session-id", sessionID, "--name", name]
        if let model = options.model {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: ["--permission-mode", options.permissionMode.rawValue])
        arguments.append(contentsOf: ["--allowedTools", allowedDelegationTools])
        // Only when it is really there: a workspace whose folder has gone
        // would otherwise hand the CLI a path to nothing.
        if let settings = options.settingsPath, FileManager.default.fileExists(atPath: settings) {
            arguments.append(contentsOf: ["--settings", settings])
        }
        return arguments
    }

    // MARK: - Briefs

    /// What the orchestrator is told before the user types anything.
    ///
    /// Delivered as `--append-system-prompt` rather than a first message, so the
    /// terminal opens ready for the user's actual task.
    static func orchestratorBrief(workspace: Workspace) -> String {
        var lines: [String] = []
        lines.append("""
        You are the orchestrator for the Meshvy workspace `\(workspace.name)`.

        Your working directory is the workspace root. Every repository in this \
        workspace is checked out as a subdirectory of it, all on the branch \
        `\(workspace.branch)`:
        """)
        lines.append("")
        for repo in workspace.readyRepos {
            lines.append("- ./\(repo.name)")
        }
        lines.append("")
        lines.append("""
        ## Delegating

        Do not use the Agent tool to split this work up. Agent-tool sub-agents \
        run inside your own process, so the person watching Meshvy cannot see \
        them, open them, or talk to them.

        Instead delegate with the `meshvy` command, already on your PATH. Each \
        agent you start this way is a real Claude Code session with its own \
        terminal on the canvas, which the user can read and interrupt:

            meshvy spawn <repo> "<task>"    start an agent in that repository;
                                            prints an agent id
            meshvy wait <id>                block until it finishes, then print
                                            what it reported back
            meshvy send <id> "<message>"    type a follow-up into its terminal
            meshvy context <id>             read what that agent has been doing,
                                            without interrupting it
            meshvy status                   every agent on the board and what it
                                            is doing right now
            meshvy list                     agents currently on the board

        Work this way:

        1. Plan the change across the repositories.
        2. `meshvy spawn` one agent per repository that has work to do, giving \
           each a task scoped to its own directory. Start them all before \
           waiting on any of them, so they run concurrently.
        3. `meshvy wait` on each id and read what came back. `meshvy status` \
           tells you where they all are without blocking, and `meshvy context` \
           shows you one agent's recent work if you need to decide something \
           before it finishes.
        4. Follow up with `meshvy send` where something needs correcting, \
           integrate the results, and keep the repositories consistent.

        Do the coordination yourself and hand off the implementation. A change \
        that spans repositories stays on the `\(workspace.branch)` branch in \
        each of them and should be committed together.
        """)
        return lines.joined(separator: "\n")
    }

    static func repoBrief(workspace: Workspace, repo: WorkspaceRepo) -> String {
        let siblings = workspace.readyRepos.filter { $0.id != repo.id }.map(\.name)
        var text = """
        You are working in `\(repo.name)`, one repository of the Meshvy workspace \
        `\(workspace.name)`, checked out on branch `\(workspace.branch)`.
        """
        if !siblings.isEmpty {
            text += """


            Sibling repositories live alongside this one under \
            \(workspace.root) — \(siblings.joined(separator: ", ")). Stay inside \
            this repository unless you are asked otherwise; the orchestrator \
            coordinates changes that span several.
            """
        }
        return text
    }

    /// Name shown on the card and in `claude agents`.
    static func derivedName(role: TerminalNode.Role, context: String) -> String {
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let stem = role == .orchestrator ? "orc" : "agt"
        return "\(Workspace.slug(context))-\(stem)-\(suffix)"
    }
}
