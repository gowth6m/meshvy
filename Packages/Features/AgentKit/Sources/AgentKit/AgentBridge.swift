import Foundation
import MeshvyModels

/// The on-disk protocol the coordinator uses to start and talk to threads.
///
/// Claude's own Agent tool runs sub-agents inside the parent process — no pid,
/// no pty, nothing a terminal could attach to. To give every thread a real
/// terminal, the coordinator instead runs the `meshvy` helper, which drops a
/// request file here; Meshvy picks it up and starts an actual `claude` in its
/// own PTY on the canvas.
///
/// Files rather than a socket: the watcher already exists, it survives an app
/// restart, and the coordinator only needs a shell.
public enum AgentBridge {
    /// What the helper writes.
    public struct Request: Codable {
        public var id: String
        /// "thread" starts one; "spawn" is its older spelling, from before
        /// threads had titles. "send" and "resolve" address one by `to`.
        public var kind: String
        public var title: String?        // thread: what the work is called
        public var repo: String?         // thread: where it works; nil is the workspace root
        public var task: String?         // thread: its opening instruction
        public var to: String?           // send, resolve: target thread id
        public var message: String?      // send: what to type into it
        public var model: String?

        public init(
            id: String,
            kind: String,
            title: String? = nil,
            repo: String? = nil,
            task: String? = nil,
            to: String? = nil,
            message: String? = nil,
            model: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.repo = repo
            self.task = task
            self.to = to
            self.message = message
            self.model = model
        }
    }

    /// What Meshvy writes back, so the helper can find the session.
    public struct AgentRecord: Codable {
        public var id: String
        public var title: String?
        public var sessionId: String?
        public var repo: String?
        public var cwd: String
        public var transcriptHint: String?
        public var startedAt: Double

        public init(
            id: String,
            title: String? = nil,
            sessionId: String? = nil,
            repo: String? = nil,
            cwd: String,
            transcriptHint: String? = nil,
            startedAt: Double
        ) {
            self.id = id
            self.title = title
            self.sessionId = sessionId
            self.repo = repo
            self.cwd = cwd
            self.transcriptHint = transcriptHint
            self.startedAt = startedAt
        }
    }

    /// Creates the directories and installs the helper on disk.
    public static func install(for workspace: Workspace) {
        let fm = FileManager.default
        for path in [workspace.requestsDirectory, workspace.agentsDirectory, workspace.binDirectory] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        let helper = workspace.binDirectory + "/meshvy"
        let script = helperScript(workspace: workspace)
        // Rewrite every time so an upgraded Meshvy ships an upgraded helper.
        try? script.write(toFile: helper, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)

        // Keep the control files out of every repo's git status.
        let ignore = workspace.meshvyDirectory + "/.gitignore"
        try? "*\n".write(toFile: ignore, atomically: true, encoding: .utf8)
    }

    public static func pendingRequests(for workspace: Workspace) -> [(url: URL, request: Request)] {
        let directory = workspace.requestsDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return contents.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let url = URL(fileURLWithPath: directory + "/" + name)
            guard let data = try? Data(contentsOf: url),
                  let request = try? JSONDecoder().decode(Request.self, from: data) else {
                // Unreadable request: drop it rather than retrying forever.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return (url, request)
        }
    }

    public static func record(_ agent: AgentRecord, in workspace: Workspace) {
        guard let data = try? JSONEncoder().encode(agent) else { return }
        try? data.write(to: URL(fileURLWithPath: workspace.agentsDirectory + "/\(agent.id).json"))
    }

    /// A short id for a thread, in the same shape the helper makes them.
    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    // MARK: - Reporting back

    /// The one line Meshvy types into the coordinator when a thread finishes a
    /// turn or stops on a question, so the coordinator can tell the person
    /// without having had to wait on it.
    ///
    /// One line, whatever the thread said: it is typed into a terminal, where a
    /// newline would submit the message half-written.
    public static func report(id: String, title: String, state: ThreadState, message: String?) -> String {
        let said = message.map { " " + $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
            .map { String($0.prefix(300)) } ?? ""
        let what = switch state {
        case .needsYou: "needs the person:"
        case .ready: "finished its turn:"
        case .stopped: "stopped."
        default: "is \(state.label.lowercased())."
        }
        return "[meshvy] Thread “\(title)” (\(id)) \(what)\(said) — meshvy context \(id) for more."
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// One row of `meshvy threads`.
    public struct StatusRow: Codable {
        public var id: String?
        public var title: String
        public var repo: String?
        public var state: String
        public var line: String?

        public init(
            id: String? = nil,
            title: String,
            repo: String? = nil,
            state: String,
            line: String? = nil
        ) {
            self.id = id
            self.title = title
            self.repo = repo
            self.state = state
            self.line = line
        }
    }

    /// Publishes what every agent on the board is doing, so one agent can ask
    /// about the others without interrupting them. Hook payloads are consumed
    /// and deleted as they arrive, so this file is the only place the resolved
    /// state is readable from outside the app.
    public static func publishStatus(_ rows: [StatusRow], in workspace: Workspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(rows) else { return }
        try? data.write(to: URL(fileURLWithPath: workspace.meshvyDirectory + "/status.json"), options: .atomic)
    }

    // MARK: - The helper

    /// A small bash client. It only reads and writes files, plus Claude Code's
    /// own session registry, so it keeps working if Meshvy is restarted.
    ///
    /// `spawn` and `status` are the commands from before threads, kept so a
    /// coordinator briefed by an older Meshvy still gets an answer.
    private static func helperScript(workspace: Workspace) -> String {
        """
        #!/usr/bin/env bash
        # meshvy — start and talk to threads in this Meshvy workspace.
        #
        #   meshvy thread "<title>" "<task>" [--repo <repo>]
        #                                  start a thread, print its id
        #   meshvy send <id> "<message>"   a follow-up to that thread
        #   meshvy threads                 every thread and where it stands
        #   meshvy context <id>            print what that thread has been doing
        #   meshvy wait <id>               block until it finishes its turn, print its report
        #   meshvy resolve <id>            put a finished thread away
        #
        # Each thread is its own Claude Code session, with its own terminal.
        set -euo pipefail

        ROOT="\(workspace.root)"
        BRIDGE="$ROOT/.meshvy"
        SESSIONS="$HOME/.claude/sessions"

        die() { echo "meshvy: $*" >&2; exit 1; }

        new_id() { date +%s%N | shasum | head -c 10; }

        start_thread() {
          local title="$1" task="$2" repo="$3"
          [ -z "$repo" ] || [ -d "$ROOT/$repo" ] || die "no repository '$repo' in this workspace"

          local id; id="$(new_id)"
          python3 - "$BRIDGE/requests/$id.json" "$id" "$title" "$task" "$repo" <<'PY'
        import json, sys
        path, id, title, task, repo = sys.argv[1:6]
        json.dump({"id": id, "kind": "thread", "title": title, "task": task,
                   "repo": repo or None}, open(path, "w"))
        PY

          # Meshvy answers by writing agents/<id>.json.
          for _ in $(seq 1 100); do
            [ -f "$BRIDGE/agents/$id.json" ] && { echo "$id"; return 0; }
            sleep 0.2
          done
          die "Meshvy did not pick up the request (is the app running?)"
        }

        cmd_thread() {
          local usage="usage: meshvy thread \\"<title>\\" \\"<task>\\" [--repo <repo>]"
          local title="" task="" repo=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --repo) repo="${2:-}"; shift 2 || die "$usage" ;;
              --repo=*) repo="${1#--repo=}"; shift ;;
              *)
                if [ -z "$title" ]; then title="$1"
                elif [ -z "$task" ]; then task="$1"
                elif [ -z "$repo" ]; then repo="$1"
                else die "$usage"; fi
                shift ;;
            esac
          done
          [ -n "$title" ] && [ -n "$task" ] || die "$usage"
          start_thread "$title" "$task" "$repo"
        }

        # The older form: no title, always a repository.
        cmd_spawn() {
          local repo="${1:-}" task="${2:-}"
          [ -n "$repo" ] && [ -n "$task" ] || die "usage: meshvy spawn <repo> \\"<task>\\""
          start_thread "$(printf '%s' "$task" | head -c 40)" "$task" "$repo"
        }

        cmd_resolve() {
          local id="${1:-}"; [ -n "$id" ] || die "usage: meshvy resolve <id>"
          [ -f "$BRIDGE/agents/$id.json" ] || die "unknown thread '$id'"
          local rid; rid="$(new_id)"
          python3 - "$BRIDGE/requests/$rid.json" "$rid" "$id" <<'PY'
        import json, sys
        path, rid, to = sys.argv[1:4]
        json.dump({"id": rid, "kind": "resolve", "to": to}, open(path, "w"))
        PY
          echo "resolved"
        }

        session_of() {
          python3 - "$BRIDGE/agents/$1.json" <<'PY'
        import json, sys
        try: print(json.load(open(sys.argv[1])).get("sessionId") or "")
        except Exception: print("")
        PY
        }

        # Claude Code records a live session's status as busy or idle.
        status_of() {
          python3 - "$SESSIONS" "$1" <<'PY'
        import json, os, sys
        directory, session = sys.argv[1], sys.argv[2]
        for name in os.listdir(directory) if os.path.isdir(directory) else []:
            if not name.endswith(".json"): continue
            try: d = json.load(open(os.path.join(directory, name)))
            except Exception: continue
            if d.get("sessionId") == session:
                print(d.get("status") or "idle"); break
        else:
            print("gone")
        PY
        }

        last_reply() {
          python3 - "$1" <<'PY'
        import glob, json, os, sys
        session = sys.argv[1]
        hits = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % session))
        if not hits: sys.exit(0)
        text = ""
        for line in open(hits[0]):
            try: r = json.loads(line)
            except Exception: continue
            if r.get("type") != "assistant": continue
            for b in (r.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                    text = b["text"]
        print(text)
        PY
        }

        cmd_wait() {
          local id="${1:-}"; [ -n "$id" ] || die "usage: meshvy wait <id>"
          local session; session="$(session_of "$id")"
          [ -n "$session" ] || die "unknown thread '$id'"

          # Let it start before deciding it has finished.
          local seen_busy=0
          for _ in $(seq 1 60); do
            [ "$(status_of "$session")" = "busy" ] && { seen_busy=1; break; }
            sleep 1
          done

          local quiet=0
          while :; do
            case "$(status_of "$session")" in
              busy) quiet=0 ;;
              gone) break ;;
              *)
                [ "$seen_busy" = "1" ] || { sleep 2; continue; }
                quiet=$((quiet + 1))
                # Two consecutive idle reads: the turn really has ended.
                [ "$quiet" -ge 2 ] && break
                ;;
            esac
            sleep 2
          done
          last_reply "$session"
        }

        cmd_send() {
          local id="${1:-}" message="${2:-}"
          [ -n "$id" ] && [ -n "$message" ] || die "usage: meshvy send <id> \\"<message>\\""
          local rid; rid="$(new_id)"
          python3 - "$BRIDGE/requests/$rid.json" "$rid" "$id" "$message" <<'PY'
        import json, sys
        path, rid, to, message = sys.argv[1:5]
        json.dump({"id": rid, "kind": "send", "to": to, "message": message}, open(path, "w"))
        PY
          echo "sent"
        }

        cmd_list() {
          python3 - "$BRIDGE/agents" <<'PY'
        import json, os, sys
        directory = sys.argv[1]
        for name in sorted(os.listdir(directory)) if os.path.isdir(directory) else []:
            if not name.endswith(".json"): continue
            try: d = json.load(open(os.path.join(directory, name)))
            except Exception: continue
            print("%s  %-28s %s" % (d.get("id"), d.get("title") or "-", d.get("repo") or "workspace root"))
        PY
        }

        # Pull, not push: an agent reads another's work when it decides that is
        # relevant, and the one being read is never interrupted.
        cmd_context() {
          local id="${1:-}" turns="${2:-6}"
          [ -n "$id" ] || die "usage: meshvy context <id> [turns]"
          local session; session="$(session_of "$id")"
          [ -n "$session" ] || die "unknown thread '$id'"
          python3 - "$session" "$turns" <<'PY'
        import glob, json, os, sys
        session, turns = sys.argv[1], int(sys.argv[2])
        hits = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % session))
        if not hits:
            print("no transcript yet"); sys.exit(0)
        rows = []
        for line in open(hits[0]):
            try: r = json.loads(line)
            except Exception: continue
            kind = r.get("type")
            if kind not in ("user", "assistant"): continue
            content = (r.get("message") or {}).get("content")
            if isinstance(content, str):
                rows.append(("you" if kind == "user" else "agent", content))
                continue
            for b in content or []:
                if not isinstance(b, dict): continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    rows.append(("you" if kind == "user" else "agent", b["text"]))
                elif b.get("type") == "tool_use":
                    arg = b.get("input") or {}
                    detail = arg.get("file_path") or arg.get("command") or arg.get("pattern") or ""
                    rows.append(("tool", "%s %s" % (b.get("name"), str(detail)[:120])))
        for who, text in rows[-(turns * 4):]:
            body = " ".join(str(text).split())[:600]
            print("[%s] %s" % (who, body))
        PY
        }

        cmd_status() {
          python3 - "$BRIDGE/status.json" <<'PY'
        import json, sys
        try: rows = json.load(open(sys.argv[1]))
        except Exception: rows = []
        if not rows:
            print("no threads yet (or Meshvy is not running)"); sys.exit(0)
        for r in rows:
            print("%-12s %-10s %-22s %s" % (
                r.get("id") or "-", r.get("state") or "?",
                r.get("title") or r.get("repo") or "-", (r.get("line") or "")[:100]))
        PY
        }

        case "${1:-}" in
          thread)  shift; cmd_thread "$@" ;;
          send)    shift; cmd_send "$@" ;;
          threads|status) shift; cmd_status "$@" ;;
          context) shift; cmd_context "$@" ;;
          wait)    shift; cmd_wait "$@" ;;
          resolve) shift; cmd_resolve "$@" ;;
          list)    shift; cmd_list "$@" ;;
          spawn)   shift; cmd_spawn "$@" ;;
          *) die "usage: meshvy {thread|send|threads|context|wait|resolve}" ;;
        esac
        """
    }
}
