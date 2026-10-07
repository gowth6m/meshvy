import AppKit
import Foundation

/// Starts `claude` processes against a link.
///
/// Forge does not host the agent — it starts the real CLI with the right working
/// directory, the sibling repos granted via `--add-dir`, and a pre-assigned
/// session id. The CLI registers itself in `~/.claude/sessions` within about half
/// a second, so a launched agent shows up on the board through the same path as
/// any session the user started themselves, and its transcript is readable in the
/// inspector while it runs.
struct AgentLauncher {
    struct Launched {
        var sessionID: String
        var name: String
        var cwd: String
        var background: Bool
    }

    enum LaunchError: Error, LocalizedError {
        case claudeNotFound
        case directoryMissing(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Could not find the `claude` executable on your PATH."
            case .directoryMissing(let path):
                return "\(path) does not exist."
            case .processFailed(let message):
                return message
            }
        }
    }

    /// Resolved once; `claude` is usually a Homebrew or local-bin shim.
    static let claudePath: String? = {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to asking the login shell, which picks up version managers.
        let which = Shell.run("/bin/zsh", ["-lc", "command -v claude"], cwd: nil, timeout: 8)
        let path = which.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return which.ok && !path.isEmpty ? path : nil
    }()

    @discardableResult
    func launch(_ request: AgentLaunch) throws -> Launched {
        guard let claude = Self.claudePath else { throw LaunchError.claudeNotFound }
        guard FileManager.default.fileExists(atPath: request.cwd) else {
            throw LaunchError.directoryMissing(request.cwd)
        }

        let sessionID = UUID().uuidString.lowercased()
        let name = request.name.isEmpty ? Self.derivedName(for: request) : request.name
        let prompt = Self.composePrompt(request)
        let arguments = Self.arguments(request, sessionID: sessionID, name: name, prompt: prompt)

        if request.runsInBackground {
            try runDetached(claude: claude, arguments: arguments, cwd: request.cwd, sessionID: sessionID)
        } else {
            try runInTerminal(claude: claude, arguments: arguments, cwd: request.cwd)
        }

        return Launched(sessionID: sessionID, name: name, cwd: request.cwd, background: request.runsInBackground)
    }

    // MARK: - Argument construction

    static func arguments(_ request: AgentLaunch, sessionID: String, name: String, prompt: String) -> [String] {
        var arguments: [String] = ["--session-id", sessionID, "--name", name]

        for directory in request.additionalDirs where directory != request.cwd {
            arguments.append(contentsOf: ["--add-dir", directory])
        }
        if let model = request.model {
            arguments.append(contentsOf: ["--model", model])
        }
        arguments.append(contentsOf: ["--permission-mode", request.permissionMode])

        if request.runsInBackground {
            // Headless, but still streaming so the transcript fills in as it works.
            arguments.append(contentsOf: ["--print", "--output-format", "stream-json", "--verbose"])
        }
        arguments.append(prompt)
        return arguments
    }

    /// Prepends what the agent needs to know about the link it is working in:
    /// which repos are checked out where, and — for an orchestrator — that it is
    /// expected to split the work across teammates rather than do it all itself.
    static func composePrompt(_ request: AgentLaunch) -> String {
        // The brief is wrapped so `PromptCleaner` can strip it back out: without
        // that, every launched agent's card would be titled with our boilerplate
        // instead of the task the user typed.
        var brief: [String] = []
        if let summary = request.brief, !summary.isEmpty {
            brief.append(summary)
        }
        if request.role == .orchestrator {
            brief.append("""
            You are the orchestrator here. Plan the work across the repositories \
            above, then dispatch teammates with the Agent tool to carry out the \
            independent parts in parallel, giving each one a scoped task and the \
            exact paths it owns. Launch agents whose work does not overlap \
            concurrently rather than one after another. Review what comes back, \
            integrate it, and keep the repositories consistent with each other. \
            Do the coordination yourself; hand off the implementation.
            """)
        }
        guard !brief.isEmpty else { return request.prompt }
        return "<forge-brief>\n" + brief.joined(separator: "\n\n") + "\n</forge-brief>\n\n" + request.prompt
    }

    /// Human-readable context block describing the link's checkouts.
    static func linkSummary(link: LinkedWorktree, workspace: Workspace) -> String {
        var lines = ["You are working in the Forge link `\(link.name)` on branch `\(link.branch)`."]
        if let intent = link.intent, !intent.isEmpty {
            lines.append("LinkedWorktree intent: \(intent)")
        }
        lines.append("")
        lines.append("It spans \(link.checkouts.filter(\.isReady).count) repositories, each checked out on that branch:")
        for checkout in link.checkouts where checkout.isReady {
            lines.append("- \(checkout.repoName): \(checkout.path)")
        }
        lines.append("")
        lines.append("""
        All of these paths are writable. Changes that span repositories belong on \
        this one branch name in each of them, and should be committed together so \
        the repositories stay consistent.
        """)
        return lines.joined(separator: "\n")
    }

    /// Context block for an agent that owns the entire workspace: every repo,
    /// its main checkout, and every linked worktree currently cut across them.
    static func workspaceSummary(workspace: Workspace, linkedWorktrees: [LinkedWorktree]) -> String {
        var lines = ["You are working across the Forge workspace `\(workspace.name)`."]
        lines.append("")
        lines.append("It contains \(workspace.repos.count) repositories:")
        for repo in workspace.repos {
            lines.append("- \(repo.name): \(repo.path)")
        }

        let live = linkedWorktrees.filter { !$0.checkouts.filter(\.isReady).isEmpty }
        if !live.isEmpty {
            lines.append("")
            lines.append("""
            Each of the following is a linked worktree: one branch name checked \
            out simultaneously in several of those repositories, so a change \
            spanning them is one unit of work.
            """)
            for link in live {
                lines.append("")
                lines.append("• `\(link.name)` on branch `\(link.branch)`"
                             + (link.intent.map { " — \($0)" } ?? ""))
                for checkout in link.checkouts where checkout.isReady {
                    lines.append("    - \(checkout.repoName): \(checkout.path)")
                }
            }
        }

        lines.append("")
        lines.append("""
        Every path listed above is writable. When a change spans repositories, \
        make it on the same branch name in each of them and commit together so \
        the repositories stay consistent.
        """)
        return lines.joined(separator: "\n")
    }

    static func derivedName(for request: AgentLaunch) -> String {
        let base: String
        switch request.scope {
        case .workspace: base = "workspace"
        default: base = URL(fileURLWithPath: request.cwd).lastPathComponent
        }
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(base)-\(request.role == .orchestrator ? "orc" : "agt")-\(suffix)"
    }

    // MARK: - Process management

    /// Background agents are detached: they outlive Forge, and their output is
    /// tee'd to a log so a crashed run can still be inspected. The live board
    /// picks them up from the session registry, not from this handle.
    private func runDetached(claude: String, arguments: [String], cwd: String, sessionID: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_ENTRYPOINT"] = "forge"
        process.environment = environment

        let logDirectory = FileStore<SavedLayout>.supportDirectory().appendingPathComponent("agent-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let logURL = logDirectory.appendingPathComponent("\(sessionID).jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            throw LaunchError.processFailed(String(describing: error))
        }
    }

    /// Opens a Terminal window so the agent can be driven interactively.
    private func runInTerminal(claude: String, arguments: [String], cwd: String) throws {
        let command = ([claude] + arguments).map(Self.shellQuote).joined(separator: " ")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(Self.shellQuote(cwd)) && clear && \(Self.appleScriptEscape(command))"
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            throw LaunchError.processFailed("Could not build the Terminal command.")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error, let message = error[NSAppleScript.errorMessage] as? String {
            throw LaunchError.processFailed(message)
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command is embedded in an AppleScript string literal, so quotes and
    /// backslashes need escaping a second time.
    static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
