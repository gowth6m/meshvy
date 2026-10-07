import Foundation

/// Builds the `claude` invocation a terminal node runs.
///
/// Forge does not host the agent. It starts the real CLI inside a PTY with a
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
        var permissionMode: String = "acceptEdits"
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
        options: Options = Options()
    ) -> [String] {
        base(sessionID: sessionID, name: name, options: options)
            + ["--append-system-prompt", repoBrief(workspace: workspace, repo: repo)]
    }

    private static func base(sessionID: String, name: String, options: Options) -> [String] {
        var arguments = [claudePath, "--session-id", sessionID, "--name", name]
        if let model = options.model {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: ["--permission-mode", options.permissionMode])
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
        You are the orchestrator for the Forge workspace `\(workspace.name)`.

        Your working directory is the workspace root. Every repository in this \
        workspace is checked out as a subdirectory of it, all on the branch \
        `\(workspace.branch)`:
        """)
        lines.append("")
        for repo in workspace.readyRepos {
            lines.append("- ./\(repo.name)  (from \(repo.originPath))")
        }
        lines.append("")
        lines.append("""
        Work this way: plan the task across the repositories, then dispatch a \
        sub-agent per repository with the Agent tool, giving each one a scoped \
        task and the exact directory it owns. Run sub-agents whose work does not \
        overlap concurrently rather than one after another. Review what comes \
        back, integrate it, and keep the repositories consistent with each other.

        Do the coordination yourself and hand off the implementation. A change \
        that spans repositories stays on the `\(workspace.branch)` branch in each \
        of them and should be committed together.
        """)
        return lines.joined(separator: "\n")
    }

    static func repoBrief(workspace: Workspace, repo: WorkspaceRepo) -> String {
        let siblings = workspace.readyRepos.filter { $0.id != repo.id }.map(\.name)
        var text = """
        You are working in `\(repo.name)`, one repository of the Forge workspace \
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
