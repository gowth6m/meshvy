import Foundation
import Testing

@testable import FloorplanKit

@Suite("Floorplan")
struct FloorplanTests {
    @Test("the address comes from open.mjs's FLOORPLAN line")
    func urlFromOpenOutput() {
        let output = """
        FLOORPLAN  http://127.0.0.1:4378/  (not opened in a browser (--no-open): open the URL yourself)
        ASK  works: questions run through Claude Code
        SERVER  runs in the background
        """
        #expect(Floorplan.url(fromOpenOutput: output) == "http://127.0.0.1:4378/")
    }

    @Test("anything but a local address is not taken for the map")
    func urlMustBeLocal() {
        #expect(Floorplan.url(fromOpenOutput: "FLOORPLAN  https://example.com/  (x)") == nil)
        #expect(Floorplan.url(fromOpenOutput: "✗ No built map here yet. Run build.mjs first.") == nil)
        #expect(Floorplan.url(fromOpenOutput: "") == nil)
    }

    @Test("node versions are read by their major number")
    func nodeMajor() {
        #expect(Floorplan.nodeMajor(fromVersion: "v20.11.1\n") == 20)
        #expect(Floorplan.nodeMajor(fromVersion: "18.0.0") == 18)
        #expect(Floorplan.nodeMajor(fromVersion: "nonsense") == nil)
    }

    @Test("versions compare numerically, not as text")
    func versionOrder() {
        #expect(Floorplan.compareVersions("v20.1.0", "v9.11.2") > 0)
        #expect(Floorplan.compareVersions("v18.2", "v18.10") < 0)
        #expect(Floorplan.compareVersions("v22.0.0", "v22.0.0") == 0)
    }

    @Test("Node is looked for on the PATH first, then where installers put it")
    func nodeCandidates() {
        let candidates = Floorplan.nodeCandidates(environment: ["PATH": "/custom/bin:/usr/local/bin"], home: "/Users/me")
        #expect(candidates.first == "/custom/bin/node")
        #expect(candidates.contains("/opt/homebrew/bin/node"))
        #expect(candidates.contains("/Users/me/.volta/bin/node"))
        // /usr/local/bin was on the PATH and is a default too: listed once
        #expect(candidates.filter { $0 == "/usr/local/bin/node" }.count == 1)
    }

    @Test("a map run may run exactly the engine's own scripts, and read and write")
    func allowedTools() {
        let rules = Floorplan.allowedTools(skillDirectory: "/App/floorplan")
        let commands = rules.filter { $0.hasPrefix("Bash(") }
        #expect(commands.count == Floorplan.scripts.count)
        #expect(commands.contains("Bash(node /App/floorplan/scripts/scan.mjs *)"))
        #expect(commands.allSatisfy { $0.hasPrefix("Bash(node /App/floorplan/scripts/") })
        #expect(rules.contains("Read"))
    }

    @Test("the map task points at the bundled skill and the workspace root")
    func task() {
        let task = Floorplan.task(skillDirectory: "/App/floorplan", root: "/Users/me/.meshvy/ws", refresh: false)
        #expect(task.contains("/App/floorplan/SKILL.md"))
        #expect(task.contains("`/Users/me/.meshvy/ws`"))
        #expect(task.contains("Do not run open.mjs"))
        #expect(!task.contains("refresh it as SKILL.md describes"))

        let refresh = Floorplan.task(skillDirectory: "/App/floorplan", root: "/ws", refresh: true)
        #expect(refresh.contains("refresh it as SKILL.md describes"))
    }

    @Test("the engine is found beside a checkout's binary, or by override")
    func skillDirectory() throws {
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-floorplan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkout) }
        let skill = checkout.appendingPathComponent("Engine/Floorplan/skills/floorplan")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: floorplan\n---\n".utf8).write(to: skill.appendingPathComponent("SKILL.md"))

        let binary = checkout.appendingPathComponent(".build/debug/Meshvy")
        let found = Floorplan.skillDirectory(environment: [:], resources: nil, executable: binary)
        #expect(found == skill.standardizedFileURL.path)

        let overridden = Floorplan.skillDirectory(
            environment: ["MESHVY_FLOORPLAN_DIR": skill.path], resources: nil, executable: nil)
        #expect(overridden == skill.standardizedFileURL.path)

        #expect(Floorplan.skillDirectory(environment: [:], resources: nil, executable: nil) == nil)
    }

    @Test("a map counts once both its graph and its page are written")
    func hasMap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshvy-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let map = URL(fileURLWithPath: Floorplan.mapDirectory(root: root.path))
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        #expect(!Floorplan.hasMap(root: root.path))
        try Data("{}".utf8).write(to: map.appendingPathComponent("graph.json"))
        #expect(!Floorplan.hasMap(root: root.path))
        try Data("<!doctype html>".utf8).write(to: map.appendingPathComponent("index.html"))
        #expect(Floorplan.hasMap(root: root.path))
    }

    // MARK: - MapRun

    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test("an engine script in a Bash call reads as the step it is")
    func progressFromScripts() {
        let event = MapRun.parse(line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"node /App/floorplan/scripts/scan.mjs /ws"}}]}}"#))
        #expect(event == .progress("Scanning the repositories"))
    }

    @Test("reading a file shows the file's name")
    func progressFromRead() {
        let event = MapRun.parse(line(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Read","input":{"file_path":"/ws/api/src/server.js"}}]}}"#))
        #expect(event == .progress("Reading server.js"))
    }

    @Test("the result line is the report, or the error")
    func result() {
        #expect(MapRun.parse(line(#"{"type":"result","subtype":"success","is_error":false,"result":"Mapped 3 parts."}"#))
            == .result("Mapped 3 parts.", isError: false))
        #expect(MapRun.parse(line(#"{"type":"result","subtype":"error_max_turns","is_error":true}"#))
            == .result("error_max_turns", isError: true))
    }

    @Test("other lines are ignored")
    func ignored() {
        #expect(MapRun.parse(line(#"{"type":"system","subtype":"init"}"#)) == nil)
        #expect(MapRun.parse(line("not json")) == nil)
    }

    @Test("the prompt goes on stdin, so the tool list cannot swallow it")
    func arguments() {
        let arguments = MapRun.arguments(skillDirectory: "/App/floorplan", model: nil)
        #expect(arguments.first == "-p")
        #expect(arguments.contains("stream-json"))
        #expect(!arguments.contains("--model"))
        #expect(arguments.last == "Bash(node /App/floorplan/scripts/status.mjs *)")
    }
}
