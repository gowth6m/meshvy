import Foundation
import MeshvyModels

/// How an agent drives a browser node.
///
/// The delegation helper (`AgentBridge`) is a bash script because an
/// orchestrator only needs to *start* things, and a shell command is the
/// clearest way to say so. Driving a page is different: it is a conversation of
/// dozens of calls, each with a structured result, and that is what tools are
/// for. So this bridge ships a real MCP server — registered with
/// `--mcp-config`, so every session Meshvy starts has `browser_*` tools
/// alongside Read and Edit, with no setup from the user.
///
/// The server itself is a small stdio program that does no work: it writes a
/// request file, waits for the app to write the answer back, and prints it.
/// Files rather than a socket, for the same reasons as `AgentBridge` — the
/// watcher already exists and nothing is left listening on a port.
public enum BrowserBridge {
    /// `<workspace>/.meshvy/browser`
    public static func directory(for workspace: Workspace) -> String {
        workspace.meshvyDirectory + "/browser"
    }

    public static func requestsDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/requests"
    }

    public static func responsesDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/responses"
    }

    /// Where screenshots land. An agent is handed the path and reads it with
    /// the Read tool, which already knows how to look at a PNG.
    public static func shotsDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/shots"
    }

    public static func serverPath(for workspace: Workspace) -> String {
        workspace.binDirectory + "/meshvy-browser-mcp"
    }

    public static func configPath(for workspace: Workspace) -> String {
        workspace.meshvyDirectory + "/mcp.json"
    }

    /// Tool prefix, so the whole server can be pre-approved in one string.
    public static let toolPrefix = "mcp__meshvy-browser"

    /// What the MCP server writes.
    public struct Request: Codable {
        public var id: String
        /// `open` | `list` | `navigate` | `snapshot` | `click` | `type` |
        /// `eval` | `console` | `screenshot` | `wait` | `close` | `back` |
        /// `forward` | `reload`
        public var op: String
        /// Short id or title of the browser node to act on. Nil means the only
        /// one on the board, or the one this agent opened.
        public var node: String?
        public var url: String?
        public var title: String?
        public var selector: String?
        public var text: String?
        public var js: String?
        public var submit: Bool?
        public var timeoutMs: Int?
        public var limit: Int?

        public init(
            id: String,
            op: String,
            node: String? = nil,
            url: String? = nil,
            title: String? = nil,
            selector: String? = nil,
            text: String? = nil,
            js: String? = nil,
            submit: Bool? = nil,
            timeoutMs: Int? = nil,
            limit: Int? = nil
        ) {
            self.id = id
            self.op = op
            self.node = node
            self.url = url
            self.title = title
            self.selector = selector
            self.text = text
            self.js = js
            self.submit = submit
            self.timeoutMs = timeoutMs
            self.limit = limit
        }
    }

    public struct Response: Codable {
        public var id: String
        public var ok: Bool
        public var result: String?
        public var error: String?

        public init(
            id: String,
            ok: Bool,
            result: String? = nil,
            error: String? = nil
        ) {
            self.id = id
            self.ok = ok
            self.result = result
            self.error = error
        }
    }

    // MARK: - Install

    public static func install(for workspace: Workspace) {
        let fm = FileManager.default
        for path in [
            requestsDirectory(for: workspace),
            responsesDirectory(for: workspace),
            shotsDirectory(for: workspace)
        ] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        let server = serverPath(for: workspace)
        // Rewritten every launch, so an upgraded Meshvy ships upgraded tools.
        try? serverScript(workspace: workspace).write(toFile: server, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server)

        let config: [String: Any] = [
            "mcpServers": [
                "meshvy-browser": [
                    "command": server,
                    "args": [String]()
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath(for: workspace)), options: .atomic)
    }

    public static func pendingRequests(for workspace: Workspace) -> [(url: URL, request: Request)] {
        let directory = requestsDirectory(for: workspace)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return contents.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let url = URL(fileURLWithPath: directory + "/" + name)
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(Request.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url, request)
        }
    }

    public static func answer(_ response: Response, in workspace: Workspace) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        let directory = responsesDirectory(for: workspace)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Written under a temporary name and renamed, so the server can never
        // read a half-written answer.
        let part = URL(fileURLWithPath: directory + "/\(response.id).part")
        let final = URL(fileURLWithPath: directory + "/\(response.id).json")
        try? data.write(to: part, options: .atomic)
        try? FileManager.default.removeItem(at: final)
        try? FileManager.default.moveItem(at: part, to: final)
    }

    /// Drops answers nobody collected. A `wait` that timed out on the agent's
    /// side leaves one behind, and they are worthless a minute later.
    public static func sweepStaleResponses(for workspace: Workspace) {
        let fm = FileManager.default
        let directory = responsesDirectory(for: workspace)
        for name in (try? fm.contentsOfDirectory(atPath: directory)) ?? [] {
            let path = directory + "/" + name
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > 300 else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - The brief

    /// What every agent is told about the browser, appended to its system
    /// prompt. Short on purpose: the tool descriptions carry the detail.
    public static let brief = """
    ## Looking at the running application

    You have a browser on the Meshvy canvas, driven with the `browser_*` tools. \
    It is a real page the person can watch and click at the same time as you, \
    not a headless fetch — use it to check your own work:

    - `browser_open` points one at a URL, opening a node on the board if there \
      is not one already. A dev server you started yourself is the usual target.
    - `browser_snapshot` is the tool to reach for first. It returns the page's \
      text plus every control with a CSS selector; pass those selectors back to \
      `browser_click` and `browser_type`.
    - `browser_console` is how you see what the page logged and what it threw. \
      Check it after anything you changed, before saying the change works.
    - `browser_screenshot` writes a PNG and gives you the path; read it with \
      the Read tool when the layout itself is the question.

    Do not claim a web change works until you have loaded it and read either \
    the snapshot or the console.
    """

    // MARK: - The server

    private static func serverScript(workspace: Workspace) -> String {
        """
        #!/usr/bin/env python3
        \"\"\"meshvy-browser — MCP server for the browser nodes on the Meshvy canvas.

        Speaks newline-delimited JSON-RPC on stdin/stdout. Every tool call is
        handed to Meshvy as a file and answered the same way, so this process
        holds no state and can be restarted at any time.
        \"\"\"
        import json, os, sys, time, uuid

        BRIDGE = \"\(directory(for: workspace))\"
        REQUESTS = os.path.join(BRIDGE, \"requests\")
        RESPONSES = os.path.join(BRIDGE, \"responses\")

        NODE = {
            \"type\": \"string\",
            \"description\": \"Which browser node, by the short id browser_list prints. \"
                             \"Omit when there is only one on the board.\",
        }

        def tool(name, description, properties, required=()):
            return {
                \"name\": name,
                \"description\": description,
                \"inputSchema\": {
                    \"type\": \"object\",
                    \"properties\": properties,
                    \"required\": list(required),
                },
            }

        TOOLS = [
            tool(
                \"browser_open\",
                \"Open a browser node on the Meshvy canvas at a URL, or point an existing one \"
                \"at it. Use this for the application you are working on — a dev server on \"
                \"localhost, a preview build, a page you need to read. Returns the node's id. \"
                \"The person can see and click this page too.\",
                {
                    \"url\": {\"type\": \"string\", \"description\": \"http(s) URL, or a bare host:port like localhost:3000.\"},
                    \"title\": {\"type\": \"string\", \"description\": \"Optional name for the node's header.\"},
                    \"node\": NODE,
                },
                [\"url\"],
            ),
            tool(
                \"browser_list\",
                \"Every browser node on the canvas: its short id, title, URL and whether it is loading.\",
                {},
            ),
            tool(
                \"browser_navigate\",
                \"Point an existing browser node at another URL.\",
                {\"url\": {\"type\": \"string\"}, \"node\": NODE},
                [\"url\"],
            ),
            tool(
                \"browser_snapshot\",
                \"Read the page: its title, its visible text, and every control with a CSS \"
                \"selector that addresses it. Pass those selectors to browser_click and \"
                \"browser_type. Reach for this before clicking anything.\",
                {\"node\": NODE},
            ),
            tool(
                \"browser_click\",
                \"Click an element by CSS selector — use one browser_snapshot gave you.\",
                {\"selector\": {\"type\": \"string\"}, \"node\": NODE},
                [\"selector\"],
            ),
            tool(
                \"browser_type\",
                \"Type text into a field by CSS selector. Fires the input and change events a \"
                \"framework listens for, so React and Vue forms see it.\",
                {
                    \"selector\": {\"type\": \"string\"},
                    \"text\": {\"type\": \"string\"},
                    \"submit\": {\"type\": \"boolean\", \"description\": \"Press Enter afterwards.\"},
                    \"node\": NODE,
                },
                [\"selector\", \"text\"],
            ),
            tool(
                \"browser_eval\",
                \"Run JavaScript in the page and return the result. The snippet is an async \"
                \"function body, so it can await and must return a value.\",
                {\"js\": {\"type\": \"string\"}, \"node\": NODE},
                [\"js\"],
            ),
            tool(
                \"browser_console\",
                \"What the page has logged and thrown, newest last. Check this after a change \"
                \"before deciding it worked.\",
                {\"limit\": {\"type\": \"integer\", \"description\": \"How many lines, newest first. Default 40.\"}, \"node\": NODE},
            ),
            tool(
                \"browser_screenshot\",
                \"Write a PNG of the visible page and return its path. Read it with the Read \"
                \"tool when the layout itself is the question.\",
                {\"node\": NODE},
            ),
            tool(
                \"browser_wait_for\",
                \"Wait until text appears on the page, or a selector matches. Use after an \"
                \"action that navigates or loads.\",
                {
                    \"text\": {\"type\": \"string\"},
                    \"selector\": {\"type\": \"string\"},
                    \"timeoutMs\": {\"type\": \"integer\", \"description\": \"Default 10000.\"},
                    \"node\": NODE,
                },
            ),
            tool(
                \"browser_reload\",
                \"Reload the page, bypassing the cache.\",
                {\"node\": NODE},
            ),
            tool(
                \"browser_back\",
                \"Go back in that browser's history.\",
                {\"node\": NODE},
            ),
            tool(
                \"browser_close\",
                \"Close a browser node and take it off the canvas.\",
                {\"node\": NODE},
                [\"node\"],
            ),
        ]

        OPS = {
            \"browser_open\": \"open\",
            \"browser_list\": \"list\",
            \"browser_navigate\": \"navigate\",
            \"browser_snapshot\": \"snapshot\",
            \"browser_click\": \"click\",
            \"browser_type\": \"type\",
            \"browser_eval\": \"eval\",
            \"browser_console\": \"console\",
            \"browser_screenshot\": \"screenshot\",
            \"browser_wait_for\": \"wait\",
            \"browser_reload\": \"reload\",
            \"browser_back\": \"back\",
            \"browser_close\": \"close\",
        }

        def send(message):
            sys.stdout.write(json.dumps(message) + \"\\n\")
            sys.stdout.flush()

        def ask(op, arguments):
            \"\"\"Hands one request to Meshvy and waits for its answer.\"\"\"
            request_id = uuid.uuid4().hex[:12]
            payload = {\"id\": request_id, \"op\": op}
            for key in (\"node\", \"url\", \"title\", \"selector\", \"text\", \"js\", \"submit\", \"timeoutMs\", \"limit\"):
                if key in arguments and arguments[key] is not None:
                    payload[key] = arguments[key]

            try:
                os.makedirs(REQUESTS, exist_ok=True)
                part = os.path.join(REQUESTS, request_id + \".part\")
                with open(part, \"w\") as handle:
                    json.dump(payload, handle)
                os.rename(part, os.path.join(REQUESTS, request_id + \".json\"))
            except OSError as error:
                return False, \"could not reach Meshvy: %s\" % error

            # A wait is allowed to take as long as it was given, plus enough
            # slack for the app to notice the request in the first place.
            budget = 20.0 + max(0, int(payload.get(\"timeoutMs\") or 0)) / 1000.0
            answer_path = os.path.join(RESPONSES, request_id + \".json\")
            deadline = time.time() + budget
            while time.time() < deadline:
                if os.path.exists(answer_path):
                    try:
                        with open(answer_path) as handle:
                            answer = json.load(handle)
                    except Exception:
                        time.sleep(0.05)
                        continue
                    try:
                        os.remove(answer_path)
                    except OSError:
                        pass
                    return bool(answer.get(\"ok\")), answer.get(\"result\") or answer.get(\"error\") or \"\"
                time.sleep(0.08)
            return False, \"Meshvy did not answer in %ds — is the app still running?\" % int(budget)

        def handle(message):
            method = message.get(\"method\")
            request_id = message.get(\"id\")

            if method == \"initialize\":
                asked = (message.get(\"params\") or {}).get(\"protocolVersion\")
                return {
                    \"jsonrpc\": \"2.0\",
                    \"id\": request_id,
                    \"result\": {
                        \"protocolVersion\": asked or \"2025-06-18\",
                        \"capabilities\": {\"tools\": {}},
                        \"serverInfo\": {\"name\": \"meshvy-browser\", \"version\": \"1\"},
                    },
                }

            if method == \"tools/list\":
                return {\"jsonrpc\": \"2.0\", \"id\": request_id, \"result\": {\"tools\": TOOLS}}

            if method == \"tools/call\":
                params = message.get(\"params\") or {}
                name = params.get(\"name\")
                op = OPS.get(name)
                if not op:
                    return {
                        \"jsonrpc\": \"2.0\",
                        \"id\": request_id,
                        \"error\": {\"code\": -32601, \"message\": \"no tool named %s\" % name},
                    }
                ok, text = ask(op, params.get(\"arguments\") or {})
                return {
                    \"jsonrpc\": \"2.0\",
                    \"id\": request_id,
                    \"result\": {
                        \"content\": [{\"type\": \"text\", \"text\": text or (\"done\" if ok else \"failed\")}],
                        \"isError\": not ok,
                    },
                }

            if method == \"ping\":
                return {\"jsonrpc\": \"2.0\", \"id\": request_id, \"result\": {}}

            # Notifications carry no id and want no answer.
            if request_id is None:
                return None

            return {
                \"jsonrpc\": \"2.0\",
                \"id\": request_id,
                \"error\": {\"code\": -32601, \"message\": \"unsupported method %s\" % method},
            }

        def main():
            for line in sys.stdin:
                line = line.strip()
                if not line:
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                try:
                    reply = handle(message)
                except Exception as error:  # never die on one bad call
                    reply = {
                        \"jsonrpc\": \"2.0\",
                        \"id\": message.get(\"id\"),
                        \"error\": {\"code\": -32603, \"message\": str(error)},
                    }
                if reply is not None:
                    send(reply)

        if __name__ == \"__main__\":
            main()
        """
    }
}
