import Foundation
import MeshvyModels
import Testing

@testable import AgentKit

@Suite("AgentCommand")
struct AgentCommandTests {
    private let workspace = Workspace(name: "Payments revamp", branch: "payments-revamp", root: "/tmp/ws")

    private func argv(_ options: AgentCommand.Options = .init()) -> [String] {
        AgentCommand.coordinator(workspace: workspace, sessionID: "sid-1", name: "orc", options: options)
    }

    /// Value following `flag` in an argv, or nil when the flag is absent.
    private func value(of flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    // Meshvy pre-assigns the session id so it can match the CLI's own
    // transcript back to the terminal the agent is running in. If this stopped
    // being passed, every card on the board would lose its session.
    @Test("the session id and name are passed through")
    func identity() {
        let argv = argv()
        #expect(value(of: "--session-id", in: argv) == "sid-1")
        #expect(value(of: "--name", in: argv) == "orc")
    }

    @Test("the first argument is the resolved claude binary")
    func executableFirst() {
        #expect(argv().first == AgentCommand.claudePath)
    }

    @Test("the permission mode is always passed")
    func permissionMode() {
        var options = AgentCommand.Options()
        options.permissionMode = .plan
        #expect(value(of: "--permission-mode", in: argv(options)) == PermissionMode.plan.rawValue)
    }

    // `.inherit` means "whatever the user's own config says", which is
    // expressed by leaving the flag off entirely, not by passing a value.
    @Test("inherited effort leaves the flag off")
    func inheritedEffort() {
        var options = AgentCommand.Options()
        options.effort = .inherit
        #expect(!argv(options).contains("--effort"))
    }

    @Test("an explicit effort is passed")
    func explicitEffort() {
        var options = AgentCommand.Options()
        options.effort = .high
        #expect(value(of: "--effort", in: argv(options)) == "high")
    }

    @Test("no model means no --model flag")
    func noModel() {
        var options = AgentCommand.Options()
        options.model = nil
        #expect(!argv(options).contains("--model"))
    }

    // A workspace whose folder has gone would otherwise hand the CLI a path to
    // nothing, and `claude` exits rather than starting.
    @Test("a settings path that is not on disk is not passed")
    func missingSettingsPath() {
        var options = AgentCommand.Options()
        options.settingsPath = "/nonexistent/settings.json"
        #expect(!argv(options).contains("--settings"))
    }

    @Test("an mcp config that is not on disk is not passed")
    func missingMCPPath() {
        var options = AgentCommand.Options()
        options.mcpConfigPath = "/nonexistent/mcp.json"
        #expect(!argv(options).contains("--mcp-config"))
    }

    @Test("delegation and the browser tools are pre-approved")
    func allowedTools() {
        #expect(value(of: "--allowedTools", in: argv()) == AgentCommand.allowedTools)
        #expect(AgentCommand.allowedTools.contains("Bash(meshvy:*)"))
    }

    @Test("the coordinator is briefed with the workspace's repositories")
    func coordinatorBrief() {
        let brief = AgentCommand.coordinatorBrief(workspace: workspace)
        #expect(brief.contains("Payments revamp"))
        #expect(brief.contains("payments-revamp"))
    }

    // The whole model rests on the coordinator handing work out rather than
    // doing it, and on it knowing the reports typed into it are not the person.
    @Test("the coordinator is told to start threads and how reports arrive")
    func coordinatorBriefModel() {
        let brief = AgentCommand.coordinatorBrief(workspace: workspace)
        #expect(brief.contains("meshvy thread"))
        #expect(brief.contains("meshvy send"))
        #expect(brief.contains("[meshvy]"))
    }

    @Test("a derived name is branch-safe and says what the agent is")
    func derivedName() {
        let coordinator = AgentCommand.derivedName(role: .orchestrator, context: "Payments revamp")
        #expect(coordinator.hasPrefix("payments-revamp-coord-"))
        #expect(AgentCommand.derivedName(role: .repo, context: "Web").hasPrefix("web-thread-"))
    }

    @Test("derived names do not collide")
    func derivedNamesUnique() {
        let names = (0..<20).map { _ in AgentCommand.derivedName(role: .repo, context: "x") }
        #expect(Set(names).count == names.count)
    }

    @Test("a thread given a task gets it as its opening message")
    func threadTask() {
        let repo = WorkspaceRepo(id: "r", name: "api", originPath: "/tmp/api", worktreePath: "/tmp/ws/api")
        let argv = AgentCommand.thread(
            workspace: workspace, repo: repo, sessionID: "s", name: "n", task: "Fix the login bug"
        )
        #expect(argv.last == "Fix the login bug")
    }

    @Test("a thread with no task gets no trailing message")
    func threadNoTask() {
        let repo = WorkspaceRepo(id: "r", name: "api", originPath: "/tmp/api", worktreePath: "/tmp/ws/api")
        let argv = AgentCommand.thread(workspace: workspace, repo: repo, sessionID: "s", name: "n")
        #expect(argv.last != "")
        #expect(!argv.contains(""))
    }

    @Test("a thread with no repository works from the workspace root")
    func threadAtRoot() {
        let brief = AgentCommand.threadBrief(workspace: workspace, repo: nil, title: "Rename the field")
        #expect(brief.contains("workspace root"))
        #expect(brief.contains("Rename the field"))
    }
}

@Suite("AgentBridge")
struct AgentBridgeTests {
    // Typed into the coordinator's terminal, so a newline would submit it
    // half-written.
    @Test("a report is one line, whatever the thread said")
    func reportIsOneLine() {
        let line = AgentBridge.report(
            id: "abc123", title: "Fix login", state: .ready, message: "Done.\nTests pass.\r\nShipped."
        )
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(line.hasPrefix("[meshvy]"))
        #expect(line.contains("abc123"))
        #expect(line.contains("Fix login"))
    }

    @Test("a thread waiting on the person says so")
    func reportNeedsYou() {
        let line = AgentBridge.report(id: "x", title: "T", state: .needsYou, message: "Allow Bash?")
        #expect(line.contains("needs the person"))
        #expect(line.contains("Allow Bash?"))
    }

    @Test("thread ids are short and distinct")
    func ids() {
        let ids = (0..<50).map { _ in AgentBridge.newID() }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 10 })
    }
}

@Suite("AgentHooks")
struct AgentHooksTests {
    // These are blocking prompts the CLI shows before it will do anything. The
    // board has to recognise them from the terminal's screen text, because no
    // hook fires while one is up.
    @Test("recognises the startup prompts that need a keypress", arguments: [
        "I trust this folder",
        "Do you trust the files in this folder?",
        "Continue without these settings",
        "Choose the text style",
    ])
    func recognisesPrompt(screen: String) {
        let message = AgentHooks.startupPrompt(onScreen: screen)
        #expect(message != nil)
        #expect(message?.hasSuffix("press Enter") == true)
    }

    @Test("ordinary output is not mistaken for a prompt")
    func ignoresOrdinaryOutput() {
        #expect(AgentHooks.startupPrompt(onScreen: "Running tests...") == nil)
        #expect(AgentHooks.startupPrompt(onScreen: "") == nil)
    }

    @Test("hook paths hang off the workspace's own directory")
    func paths() {
        let workspace = Workspace(name: "Demo", branch: "demo", root: "/tmp/ws")
        #expect(AgentHooks.eventsDirectory(for: workspace) == "/tmp/ws/.meshvy/events")
        #expect(AgentHooks.settingsPath(for: workspace) == "/tmp/ws/.meshvy/hooks.json")
        #expect(AgentHooks.scriptPath(for: workspace) == "/tmp/ws/.meshvy/bin/meshvy-hook")
    }
}
