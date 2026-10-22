import Foundation
import MeshvyModels

/// Agent status, reported by the agent rather than scraped off the screen.
///
/// Claude Code runs a command of your choosing at each point in its lifecycle.
/// Meshvy hands every session it starts a settings file whose hooks all call one
/// tiny script, `meshvy-hook`, which drops the event's JSON payload into
/// `<workspace>/.meshvy/events/`. The app drains that directory and knows
/// exactly what each agent is doing — no output parsing, no guessing from a
/// blinking cursor.
///
/// `--settings` is an *additional* source rather than a replacement, so a user's
/// own hooks in `~/.claude/settings.json` keep firing alongside these. And since
/// only sessions Meshvy launches are given the file, the hooks are a no-op in
/// your everyday terminals.
public enum AgentHooks {
    /// Events we ask for. Deliberately short: `PostToolUse` would double the
    /// file traffic of a busy agent to tell us something the next `PreToolUse`
    /// or `Stop` says anyway.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"
    ]

    public static func eventsDirectory(for workspace: Workspace) -> String {
        workspace.meshvyDirectory + "/events"
    }

    public static func settingsPath(for workspace: Workspace) -> String {
        workspace.meshvyDirectory + "/hooks.json"
    }

    public static func scriptPath(for workspace: Workspace) -> String {
        workspace.binDirectory + "/meshvy-hook"
    }

    /// Drops anything an earlier run left behind — a stale payload would report
    /// an agent that is long gone. Only on opening a workspace: doing it on
    /// every install would throw away the events of agents still running.
    public static func reset(for workspace: Workspace) {
        let fm = FileManager.default
        let directory = eventsDirectory(for: workspace)
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
            try? fm.removeItem(atPath: directory + "/" + name)
        }
    }

    /// Writes the script and the settings file. Idempotent, and rewritten every
    /// time so an upgraded Meshvy ships an upgraded hook.
    public static func install(for workspace: Workspace) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: eventsDirectory(for: workspace), withIntermediateDirectories: true)

        let script = scriptPath(for: workspace)
        try? hookScript(workspace: workspace).write(toFile: script, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        var hooks: [String: Any] = [:]
        for event in events {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": "\(script) \(event)", "timeout": 5]]
            ]
            // Tool events are filtered by tool name; we want all of them.
            if event.hasSuffix("ToolUse") { entry["matcher"] = "*" }
            hooks[event] = [entry]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: settingsPath(for: workspace)))
    }

    // MARK: - Before the session exists

    /// Dialogs Claude Code shows *before* a session starts, which therefore no
    /// hook can report: the trust prompt for a folder it has not seen, and the
    /// offer to carry on when a settings file will not parse.
    ///
    /// This is the one place Meshvy reads a terminal's screen. It is not agent
    /// status — the agent does not exist yet — and without it a worktree's
    /// first agent sits on a question looking like it is thinking.
    public static func startupPrompt(onScreen screen: String) -> String? {
        let prompts = [
            ("I trust this folder", "Asking whether to trust this folder"),
            ("Do you trust the files", "Asking whether to trust this folder"),
            ("Continue without these settings", "Asking about an unreadable settings file"),
            ("Choose the text style", "Asking which theme to use")
        ]
        for (needle, message) in prompts where screen.contains(needle) {
            return message + " — press Enter"
        }
        return nil
    }

    // MARK: - Reading

    /// One hook firing, already resolved into the state it implies.
    public struct Event {
        public var sessionID: String
        public var state: AgentState
        public var at: Date
        public var tool: String?
        public var detail: String?
        public var message: String?
        /// What was typed to start the turn — the first line of it.
        public var prompt: String?
        /// A turn starting, so the turn counter moves.
        public var startsTurn = false
        /// A tool call starting, so the tool counter moves.
        public var startsTool = false

        public init(
            sessionID: String,
            state: AgentState,
            at: Date,
            tool: String? = nil,
            detail: String? = nil,
            message: String? = nil,
            prompt: String? = nil,
            startsTurn: Bool = false,
            startsTool: Bool = false
        ) {
            self.sessionID = sessionID
            self.state = state
            self.at = at
            self.tool = tool
            self.detail = detail
            self.message = message
            self.prompt = prompt
            self.startsTurn = startsTurn
            self.startsTool = startsTool
        }
    }

    /// Reads every pending payload and deletes it. Returns them in the order
    /// they should be applied.
    ///
    /// Payloads are one file each rather than lines in a shared log: several
    /// agents write concurrently, and a 100 KB `tool_input` is more than a
    /// single atomic append.
    public static func drain(for workspace: Workspace) -> [Event] {
        let directory = eventsDirectory(for: workspace)
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".json") }

        var events: [Event] = []
        for name in names {
            let path = directory + "/" + name
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            // Delete whatever we touched: a payload we cannot read must not be
            // retried forever.
            try? fm.removeItem(atPath: path)
            guard let data, let event = parse(data) else { continue }
            events.append(event)
        }

        // `date +%s` is the best timestamp a script can produce without paying
        // for an interpreter, so events inside one second tie. Precedence breaks
        // the tie the way the lifecycle actually runs — see `AgentState`.
        return events.sorted {
            $0.at == $1.at ? $0.state.precedence < $1.state.precedence : $0.at < $1.at
        }
    }

    private static func parse(_ data: Data) -> Event? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = root["event"] as? String,
              let payload = root["payload"] as? [String: Any],
              let sessionID = payload["session_id"] as? String
        else { return nil }

        let at = (root["at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        var event = Event(sessionID: sessionID, state: .waiting, at: at)

        switch kind {
        case "SessionStart":
            event.state = .waiting
        case "UserPromptSubmit":
            event.state = .working
            event.startsTurn = true
            event.prompt = (payload["prompt"] as? String).map { AgentHooks.firstLine($0) }
        case "PreToolUse":
            event.state = .working
            event.startsTool = true
            event.tool = payload["tool_name"] as? String
            event.detail = toolDetail(
                name: event.tool, input: payload["tool_input"] as? [String: Any]
            )
        case "Notification":
            // Fired both when a tool needs approving and when the prompt has sat
            // idle for a minute. Only the first is something to come back for.
            let message = (payload["message"] as? String) ?? ""
            let isPermission = message.lowercased().contains("permission")
                || message.lowercased().contains("approve")
            event.state = isPermission ? .blocked : .waiting
            event.message = message.isEmpty ? nil : message
        case "Stop":
            event.state = .done
            event.message = (payload["last_assistant_message"] as? String)
                .map { AgentHooks.firstLine($0) }
        case "SessionEnd":
            event.state = .ended
        default:
            return nil
        }
        return event
    }

    /// The one line worth putting on a card for a tool call in flight.
    private static func toolDetail(name: String?, input: [String: Any]?) -> String? {
        guard let name, let input else { return nil }
        func string(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch name {
        case "Bash", "BashOutput":
            return string("description") ?? string("command").map { firstLine($0) }
        case "Read", "Write", "Edit", "NotebookEdit":
            return string("file_path").map(shorten)
        case "Glob", "Grep":
            return string("pattern")
        case "Task", "Agent":
            return string("description") ?? string("subagent_type")
        case "WebFetch", "WebSearch":
            return string("url") ?? string("query")
        case "TodoWrite":
            return nil
        default:
            return string("description") ?? string("path").map(shorten)
        }
    }

    /// `/long/path/to/Sources/Theme.swift` → `Sources/Theme.swift`.
    private static func shorten(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        return String(line.prefix(120))
    }

    // MARK: - The script

    /// Builtins plus `cat` and `mv`. This runs on the critical path of every
    /// tool call, so it must not pay for an interpreter start-up — Meshvy does
    /// the JSON parsing instead.
    private static func hookScript(workspace: Workspace) -> String {
        """
        #!/bin/bash
        # meshvy-hook <event> — hands one Claude Code hook payload to Meshvy.
        DIR="\(eventsDirectory(for: workspace))"
        [ -d "$DIR" ] || mkdir -p "$DIR" 2>/dev/null
        STEM="$DIR/$(date -u +%s)-$$-$RANDOM"
        {
          printf '{"event":"%s","at":%s,"payload":' "$1" "$(date -u +%s)"
          cat
          printf '}'
        } > "$STEM.part" 2>/dev/null
        # Renamed last: Meshvy must never read a half-written payload.
        mv "$STEM.part" "$STEM.json" 2>/dev/null
        # Never block the agent, whatever went wrong here.
        exit 0
        """
    }
}
