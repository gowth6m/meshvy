import Foundation

/// The on-disk protocol an orchestrator uses to put real agents on the board.
///
/// Claude's own Agent tool runs sub-agents inside the parent process — no pid,
/// no pty, nothing a terminal could attach to. To give every delegated agent a
/// real terminal, the orchestrator instead runs the `meshvy` helper, which
/// drops a request file here; Meshvy picks it up and starts an actual `claude`
/// in its own PTY on the canvas.
///
/// Files rather than a socket: the watcher already exists, it survives an app
/// restart, and the orchestrator only needs a shell.
enum AgentBridge {
    /// `<workspace>/.meshvy`
    static func directory(for workspace: Workspace) -> String {
        workspace.root + "/.meshvy"
    }

    static func requestsDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/requests"
    }

    static func agentsDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/agents"
    }

    static func binDirectory(for workspace: Workspace) -> String {
        directory(for: workspace) + "/bin"
    }

    /// What the helper writes.
    struct Request: Codable {
        var id: String
        var kind: String          // "spawn" | "send"
        var repo: String?         // spawn: which repository to work in
        var task: String?         // spawn: the agent's opening instruction
        var to: String?           // send: target agent id
        var message: String?      // send: what to type into it
        var model: String?
    }

    /// What Meshvy writes back, so the helper can find the session.
    struct AgentRecord: Codable {
        var id: String
        var sessionId: String?
        var repo: String?
        var cwd: String
        var transcriptHint: String?
        var startedAt: Double
    }

    /// Creates the directories and installs the helper on disk.
    static func install(for workspace: Workspace) {
        let fm = FileManager.default
        for path in [requestsDirectory(for: workspace), agentsDirectory(for: workspace), binDirectory(for: workspace)] {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        let helper = binDirectory(for: workspace) + "/meshvy"
        let script = helperScript(workspace: workspace)
        // Rewrite every time so an upgraded Meshvy ships an upgraded helper.
        try? script.write(toFile: helper, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)

        // Keep the control files out of every repo's git status.
        let ignore = directory(for: workspace) + "/.gitignore"
        try? "*\n".write(toFile: ignore, atomically: true, encoding: .utf8)
    }

    static func pendingRequests(for workspace: Workspace) -> [(url: URL, request: Request)] {
        let directory = requestsDirectory(for: workspace)
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

    static func record(_ agent: AgentRecord, in workspace: Workspace) {
        guard let data = try? JSONEncoder().encode(agent) else { return }
        try? data.write(to: URL(fileURLWithPath: agentsDirectory(for: workspace) + "/\(agent.id).json"))
    }

    /// One row of `meshvy status`.
    struct StatusRow: Codable {
        var id: String?
        var title: String
        var repo: String?
        var state: String
        var line: String?
    }

    /// Publishes what every agent on the board is doing, so one agent can ask
    /// about the others without interrupting them. Hook payloads are consumed
    /// and deleted as they arrive, so this file is the only place the resolved
    /// state is readable from outside the app.
    static func publishStatus(_ rows: [StatusRow], in workspace: Workspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(rows) else { return }
        try? data.write(to: URL(fileURLWithPath: directory(for: workspace) + "/status.json"), options: .atomic)
    }

    // MARK: - The helper

    /// A small bash client. It only reads and writes files, plus Claude Code's
    /// own session registry, so it keeps working if Meshvy is restarted.
    private static func helperScript(workspace: Workspace) -> String {
        """
        #!/usr/bin/env bash
        # meshvy — put real agents on the Meshvy canvas.
        #
        #   meshvy spawn <repo> "<task>"   start an agent in <repo>, print its id
        #   meshvy wait <id>               block until that agent is done, print its reply
        #   meshvy send <id> "<message>"   type a message into that agent's terminal
        #   meshvy context <id>            print what that agent has been doing
        #   meshvy status                  what every agent on the board is doing
        #   meshvy list                    agents on the board
        #
        # Each spawned agent gets its own terminal node on the canvas.
        set -euo pipefail

        ROOT="\(workspace.root)"
        BRIDGE="$ROOT/.meshvy"
        SESSIONS="$HOME/.claude/sessions"

        die() { echo "meshvy: $*" >&2; exit 1; }

        new_id() { date +%s%N | shasum | head -c 10; }

        cmd_spawn() {
          local repo="${1:-}" task="${2:-}"
          [ -n "$repo" ] || die "usage: meshvy spawn <repo> \\"<task>\\""
          [ -n "$task" ] || die "usage: meshvy spawn <repo> \\"<task>\\""
          [ -d "$ROOT/$repo" ] || die "no repository '$repo' in this workspace"

          local id; id="$(new_id)"
          python3 - "$BRIDGE/requests/$id.json" "$id" "$repo" "$task" <<'PY'
        import json, sys
        path, id, repo, task = sys.argv[1:5]
        json.dump({"id": id, "kind": "spawn", "repo": repo, "task": task}, open(path, "w"))
        PY

          # Meshvy answers by writing agents/<id>.json.
          for _ in $(seq 1 100); do
            [ -f "$BRIDGE/agents/$id.json" ] && { echo "$id"; return 0; }
            sleep 0.2
          done
          die "Meshvy did not pick up the request (is the app running?)"
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
          [ -n "$session" ] || die "unknown agent '$id'"

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
            print("%s  %s" % (d.get("id"), d.get("repo") or d.get("cwd")))
        PY
        }

        # Pull, not push: an agent reads another's work when it decides that is
        # relevant, and the one being read is never interrupted.
        cmd_context() {
          local id="${1:-}" turns="${2:-6}"
          [ -n "$id" ] || die "usage: meshvy context <id> [turns]"
          local session; session="$(session_of "$id")"
          [ -n "$session" ] || die "unknown agent '$id'"
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
            print("no agents reporting (is Meshvy running?)"); sys.exit(0)
        for r in rows:
            print("%-12s %-10s %-22s %s" % (
                r.get("id") or "-", r.get("state") or "?",
                r.get("title") or r.get("repo") or "-", (r.get("line") or "")[:100]))
        PY
        }

        case "${1:-}" in
          spawn)   shift; cmd_spawn "$@" ;;
          wait)    shift; cmd_wait "$@" ;;
          send)    shift; cmd_send "$@" ;;
          context) shift; cmd_context "$@" ;;
          status)  shift; cmd_status "$@" ;;
          list)    shift; cmd_list "$@" ;;
          *) die "usage: meshvy {spawn|wait|send|context|status|list}" ;;
        esac
        """
    }
}
