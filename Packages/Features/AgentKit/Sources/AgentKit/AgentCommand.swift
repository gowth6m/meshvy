import BrowserKit
import Foundation
import MeshvyModels
import ProcessKit

/// Builds the `claude` invocation a terminal node runs.
///
/// Meshvy does not host the agent. It starts the real CLI inside a PTY with a
/// pre-assigned session id, so the agent registers itself in
/// `~/.claude/sessions` and the board can match its transcript to the terminal
/// it is running in.
public enum AgentCommand {
    /// Resolved once; `claude` is usually a Homebrew or local-bin shim.
    public static let claudePath: String = {
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

    /// Whether there is a `claude` to run at all. The candidates above are on
    /// disk; failing those, the question goes to the same login shell every
    /// terminal is started under, since its PATH is the one an agent actually
    /// gets. Nil when the shell did not answer in time — which is not a no.
    ///
    /// Blocks on a shell, so never from the main thread.
    public static func isInstalled() -> Bool? {
        if claudePath != "claude" { return true }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = Shell.run(shell, ["-l", "-c", "command -v claude"], cwd: nil, timeout: 10)
        if result.timedOut { return nil }
        return result.status == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public struct Options {
        public var model: String? = ModelDefaults.modelID
        public var permissionMode: PermissionMode = .acceptEdits
        /// How hard it thinks. `.inherit` leaves the flag off.
        public var effort: AgentEffort = .inherit
        /// Settings file holding the status hooks — see `AgentHooks`. An
        /// additional source, so the user's own settings still apply.
        public var settingsPath: String?
        /// MCP config giving the session its `browser_*` tools — see
        /// `BrowserBridge`. An additional source, like the settings file.
        public var mcpConfigPath: String?

        public init(
            model: String? = ModelDefaults.modelID,
            permissionMode: PermissionMode = .acceptEdits,
            effort: AgentEffort = .inherit,
            settingsPath: String? = nil,
            mcpConfigPath: String? = nil
        ) {
            self.model = model
            self.permissionMode = permissionMode
            self.effort = effort
            self.settingsPath = settingsPath
            self.mcpConfigPath = mcpConfigPath
        }
    }

    /// Argv for the coordinator: the workspace's main chat, sitting at the
    /// workspace root with every repository as a subdirectory beneath it.
    public static func coordinator(
        workspace: Workspace,
        sessionID: String,
        name: String,
        options: Options = Options()
    ) -> [String] {
        base(sessionID: sessionID, name: name, options: options)
            + ["--append-system-prompt", coordinatorBrief(workspace: workspace)]
    }

    /// Argv for a thread: one piece of work, with its own agent. It runs in
    /// `repo` when it has one, otherwise at the workspace root.
    public static func thread(
        workspace: Workspace,
        repo: WorkspaceRepo?,
        sessionID: String,
        name: String,
        title: String? = nil,
        task: String? = nil,
        options: Options = Options()
    ) -> [String] {
        var arguments = base(sessionID: sessionID, name: name, options: options)
            + ["--append-system-prompt", threadBrief(workspace: workspace, repo: repo, title: title)]
        // A thread the coordinator started begins working immediately; the
        // task is its opening message, so the terminal shows it being answered.
        if let task, !task.isEmpty { arguments.append(task) }
        return arguments
    }

    /// Tools Meshvy pre-approves for the sessions it starts.
    ///
    /// Threads are started through the `meshvy` helper, so that one command is
    /// pre-approved: `acceptEdits` does not cover Bash, and a coordinator that
    /// stops to ask permission for every thread never gets going. The
    /// browser server is on the same footing — these are Meshvy's own
    /// surfaces, and an agent stopping to ask whether it may look at the page
    /// it was told to check is noise, not safety.
    public static let allowedTools = ["Bash(meshvy:*)", BrowserBridge.toolPrefix].joined(separator: ",")

    private static func base(sessionID: String, name: String, options: Options) -> [String] {
        var arguments = [claudePath, "--session-id", sessionID, "--name", name]
        if let model = options.model {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: ["--permission-mode", options.permissionMode.rawValue])
        if let effort = options.effort.flag {
            arguments.append(contentsOf: ["--effort", effort])
        }
        arguments.append(contentsOf: ["--allowedTools", allowedTools])
        // Only when it is really there: a workspace whose folder has gone
        // would otherwise hand the CLI a path to nothing.
        if let settings = options.settingsPath, FileManager.default.fileExists(atPath: settings) {
            arguments.append(contentsOf: ["--settings", settings])
        }
        if let config = options.mcpConfigPath, FileManager.default.fileExists(atPath: config) {
            arguments.append(contentsOf: ["--mcp-config", config])
        }
        return arguments
    }

    // MARK: - Briefs

    /// What the coordinator is told before the user types anything.
    ///
    /// Delivered as `--append-system-prompt` rather than a first message, so the
    /// terminal opens ready for the user's actual request.
    public static func coordinatorBrief(workspace: Workspace) -> String {
        var lines: [String] = []
        lines.append("""
        You are the coordinator for the Meshvy workspace `\(workspace.name)`. \
        This terminal is the workspace's main chat: the person types their \
        requests here, and you hand each piece of work to a thread.

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
        ## How this workspace works

        - **You coordinate; threads do the work.** For each separate piece of \
          work the person asks for, start a thread. Answer quick questions \
          yourself, and read code when you need to in order to plan or answer, \
          but leave changes to threads.
        - **One thread per piece of work**, not one per repository. A thread \
          can work in one repository or, when the work spans several, at the \
          workspace root. Start independent threads together so they run at \
          the same time.
        - **Follow-ups go to the thread that owns the work.** When the person \
          asks for a change to something a thread did, send it there instead \
          of starting another.
        - **Report back briefly.** After starting a thread, tell the person in \
          one line what you started. When a thread reports, lead with the \
          result in a sentence or two and name the thread by its title. The \
          person can open any thread and read the whole of it, so do not \
          repeat its work back.
        - **Questions for the person.** When a thread needs a decision, put \
          the question to the person plainly, with your recommendation, and \
          pass the answer on with `meshvy send`.

        ## The `meshvy` command

        Do not use the Agent tool for this work. Its sub-agents run inside \
        your own process, so the person cannot see them, open them, or talk to \
        them. Use the `meshvy` command, already on your PATH. Every thread is a \
        real Claude Code session with its own terminal, listed in the sidebar \
        and drawn on the board:

            meshvy thread "<title>" "<task>" [--repo <repo>]
                                            start a thread; prints its id.
                                            The title is two to five plain
                                            words naming the work.
            meshvy send <id> "<message>"    a follow-up to that thread
            meshvy threads                  every thread and where it stands
            meshvy context <id>             what a thread has been doing,
                                            without interrupting it
            meshvy wait <id>                block until a thread finishes its
                                            turn, then print its report
            meshvy resolve <id>             put a finished thread away

        Give each thread everything it needs in its task: the goal, what you \
        already know, and where to look. It knows only what you tell it.

        ## Reports from threads

        You do not have to wait on threads. When one finishes a turn or needs \
        the person, Meshvy types a short note into this chat that starts with \
        `[meshvy]`. Those notes come from Meshvy, not from the person. Read \
        the report, use `meshvy context <id>` if you need more, and tell the \
        person what matters in a line or two.

        Every thread works on the `\(workspace.branch)` branch of each \
        repository it touches, so a change that spans repositories lands \
        together.
        """)
        lines.append("")
        lines.append(BrowserBridge.brief)
        return lines.joined(separator: "\n")
    }

    /// What a thread is told: the one piece of work it owns, and how it hands
    /// it back.
    public static func threadBrief(workspace: Workspace, repo: WorkspaceRepo?, title: String? = nil) -> String {
        var text: String
        let work = title.map { "“\($0)”" } ?? "one piece of work"
        if let repo {
            text = """
            You are a thread in the Meshvy workspace `\(workspace.name)`, working \
            on \(work) in `\(repo.name)`, checked out on branch \
            `\(workspace.branch)`.
            """
            let siblings = workspace.readyRepos.filter { $0.id != repo.id }.map(\.name)
            if !siblings.isEmpty {
                text += """

                Sibling repositories live alongside this one under \
                \(workspace.root) — \(siblings.joined(separator: ", ")). Stay \
                inside this repository unless the work needs otherwise.
                """
            }
        } else {
            text = """
            You are a thread in the Meshvy workspace `\(workspace.name)`, working \
            on \(work). Your working directory is the workspace root; every \
            repository is a subdirectory of it, on branch `\(workspace.branch)`.
            """
        }
        text += """


        The workspace's coordinator hands out the work and relays between you \
        and the person, who can also open this thread and type to you directly. \
        Carry the work through to the end. When you finish a turn, end with a \
        short report that leads with the result: what changed, and anything \
        left open. If you need a decision only the person can make, ask it \
        plainly as the last thing you say, with the option you recommend.
        """
        text += "\n\n" + BrowserBridge.brief
        return text
    }

    /// Name shown on the card and in `claude agents`.
    public static func derivedName(role: TerminalNode.Role, context: String) -> String {
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let stem = switch role {
        case .orchestrator: "coord"
        case .repo: "thread"
        case .shell: "sh"
        }
        return "\(Workspace.slug(context))-\(stem)-\(suffix)"
    }
}
