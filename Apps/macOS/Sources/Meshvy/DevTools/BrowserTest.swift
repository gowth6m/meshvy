import AgentKit
import AppKit
import AppState
import BrowserKit
import DesignSystem
import Foundation
import MeshvyModels
import SwiftUI

/// End-to-end exercise of a browser node: `Meshvy --browsertest`.
///
/// Two halves, because the feature has two:
///
/// 1. The **engine** — a real page served over HTTP on localhost, loaded into a
///    real `WKWebView`, then snapshotted, clicked, typed into and screenshotted.
///    The page logs and throws on purpose, so the console capture is checked
///    against output it knows it should have.
/// 2. The **bridge** — the generated MCP server, spawned as a subprocess and
///    spoken to in JSON-RPC exactly as Claude Code speaks to it, with this
///    harness standing in for the app on the other side of the request files.
/// 3. The **app** — a throwaway workspace with no repositories, and request
///    files dropped into its bridge for the real store to notice, serve from a
///    real browser node, and answer.
///
/// Between them they cover every hop from an agent's tool call to the page and
/// back. Like `--selftest`, phase 3 creates and removes a workspace of its own,
/// so it may leave a different one open than you started with.
@MainActor
enum BrowserTest {
    static func run(keep: Bool) {
        let root = NSTemporaryDirectory() + "meshvy-browsertest-\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Browser Test", branch: "browsertest", root: root)
        AgentBridge.install(for: workspace)
        BrowserBridge.install(for: workspace)

        guard let server = LocalPage.start(in: root) else {
            print("BROWSERTEST FAILED: could not serve the test page")
            exit(1)
        }
        print("page:   \(server.url)")
        print("server: \(BrowserBridge.serverPath(for: workspace))")
        print("config: \(BrowserBridge.configPath(for: workspace))")

        Task { @MainActor in
            var failures: [String] = []
            failures += await checkEngine(url: server.url)
            failures += checkBridge(workspace: workspace)
            failures += await checkApp(pageURL: server.url)

            server.stop()
            if keep { print("kept: \(root)") } else { try? FileManager.default.removeItem(atPath: root) }

            guard failures.isEmpty else {
                print("BROWSERTEST FAILED:")
                for failure in failures { print("  - \(failure)") }
                exit(1)
            }
            print("BROWSERTEST OK")
            exit(0)
        }
    }

    // MARK: - The engine

    private static func checkEngine(url: String) async -> [String] {
        var failures: [String] = []
        let session = BrowserSession(id: UUID(), url: url)
        // The web view has to be in a window for `takeSnapshot` to have
        // anything to draw, exactly as it is on the canvas.
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(session.surface)
        session.surface.frame = window.contentView?.bounds ?? .zero

        await settle(session)

        if let error = session.loadError { failures.append("load failed: \(error)") }
        print("engine title: \(session.pageTitle ?? "nil")")
        if session.pageTitle != "Meshvy browser test" {
            failures.append("the engine did not pick up the page title (\(session.pageTitle ?? "nil"))")
        }

        do {
            let snapshot = try await session.snapshot()
            print("title:  \(snapshot.title ?? "-")")
            print("text:   \(snapshot.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(120))")
            print("controls: \(snapshot.elements.count)")
            for element in snapshot.elements.prefix(6) {
                print("  \(element.role) · \(element.label) → \(element.selector)")
            }
            if snapshot.title != "Meshvy browser test" {
                failures.append("snapshot title was “\(snapshot.title ?? "nil")”")
            }
            if !snapshot.text.contains("not clicked") {
                failures.append("snapshot text missing the page body")
            }
            if !snapshot.elements.contains(where: { $0.selector == "#go" }) {
                failures.append("snapshot did not offer #go as a selector")
            }
        } catch {
            failures.append("snapshot threw: \(error.localizedDescription)")
        }

        do {
            print("click:  " + (try await session.click(selector: "#go")))
            let state = try await session.evaluate("return document.getElementById('state').textContent")
            print("state:  \(state)")
            if state != "clicked" { failures.append("the click did not reach the handler (state=\(state))") }
        } catch {
            failures.append("click threw: \(error.localizedDescription)")
        }

        do {
            print("type:   " + (try await session.type(selector: "#name", text: "meshvy", submit: true)))
            let echoed = try await session.evaluate("return document.getElementById('echo').textContent")
            print("echo:   \(echoed)")
            // The page copies the field on `input`, so this is the framework
            // event path rather than just the value having been assigned.
            if echoed != "meshvy" { failures.append("typing did not fire input (echo=\(echoed))") }
        } catch {
            failures.append("type threw: \(error.localizedDescription)")
        }

        do {
            print("wait:   " + (try await session.waitFor(text: "clicked", selector: nil, timeout: 5)))
        } catch {
            failures.append("wait threw: \(error.localizedDescription)")
        }

        let logged = session.console.map(\.text).joined(separator: " | ")
        print("console: \(session.console.count) lines — \(logged.prefix(160))")
        if !session.console.contains(where: { $0.level == .log && $0.text.contains("hello from the page") }) {
            failures.append("console.log was not captured")
        }
        if !session.console.contains(where: { $0.level == .error && $0.text.contains("deliberate") }) {
            failures.append("console.error was not captured")
        }
        if !session.console.contains(where: { $0.level == .error && $0.text.contains("thrown on purpose") }) {
            failures.append("an uncaught exception was not captured")
        }

        do {
            let png = try await session.screenshot()
            print("shot:   \(png.count) bytes")
            if png.count < 1000 { failures.append("the screenshot was \(png.count) bytes") }
        } catch {
            failures.append("screenshot threw: \(error.localizedDescription)")
        }

        session.surface.removeFromSuperview()
        window.close()
        return failures
    }

    private static func settle(_ session: BrowserSession) async {
        let deadline = Date().addingTimeInterval(10)
        while session.isLoading || session.pageTitle == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The deliberate error is thrown from a timer after first paint.
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - The bridge

    /// Speaks to the generated MCP server the way Claude Code does, with this
    /// harness answering the request files in place of the app.
    private static func checkBridge(workspace: Workspace) -> [String] {
        var failures: [String] = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: BrowserBridge.serverPath(for: workspace))
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            return ["could not start the MCP server: \(error.localizedDescription)"]
        }
        defer {
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        }

        // The harness is Meshvy for the duration: it answers whatever the
        // server asks for, which is what proves the file protocol works in
        // both directions.
        let answering = Task.detached {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                for (url, request) in BrowserBridge.pendingRequests(for: workspace) {
                    try? FileManager.default.removeItem(at: url)
                    BrowserBridge.answer(
                        .init(
                            id: request.id, ok: true,
                            result: "served op=\(request.op) url=\(request.url ?? "-")", error: nil
                        ),
                        in: workspace
                    )
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        defer { answering.cancel() }

        func exchange(_ message: [String: Any], timeout: TimeInterval = 25) -> [String: Any]? {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
            return readLine(from: output, timeout: timeout)
        }

        let initialize = exchange([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "browsertest", "version": "1"]]
        ])
        if (initialize?["result"] as? [String: Any])?["serverInfo"] == nil {
            failures.append("initialize did not answer with serverInfo")
        }

        let listed = exchange(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let names = tools.compactMap { $0["name"] as? String }
        print("tools:  \(names.count) — \(names.joined(separator: ", "))")
        for expected in ["browser_open", "browser_snapshot", "browser_click", "browser_console"] {
            if !names.contains(expected) { failures.append("tools/list is missing \(expected)") }
        }

        let called = exchange([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "browser_open", "arguments": ["url": "localhost:4321"]]
        ])
        let content = ((called?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        let text = content.first?["text"] as? String ?? ""
        print("call:   \(text)")
        if !text.contains("op=open") { failures.append("tools/call did not reach the request files (got “\(text)”)") }

        let unknown = exchange([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "browser_nope", "arguments": [:]]
        ])
        if unknown?["error"] == nil { failures.append("an unknown tool was not refused") }

        return failures
    }

    // MARK: - The app

    /// The real store, serving real request files from a real browser node.
    private static func checkApp(pageURL: String) async -> [String] {
        var failures: [String] = []
        let store = MeshvyStore.shared
        store.bootstrap()

        // A workspace with no repositories is still a workspace: it has a root,
        // a bridge and a board, which is all a browser node needs.
        let name = "Meshvy Browser Test"
        // A run that died before its cleanup leaves one of these behind, and the
        // wait below would otherwise accept it as this run's and then watch the
        // real one take the active slot out from under it.
        for stale in store.workspaces where stale.name == name {
            store.deleteWorkspace(stale.id, removeWorktrees: true, force: true)
        }
        try? await Task.sleep(for: .milliseconds(300))

        store.createWorkspace(name: name, repos: [], baseRef: nil, branch: "browsertest")
        var opened: Workspace?
        for _ in 0..<80 {
            if let candidate = store.activeWorkspace, candidate.name == name {
                opened = candidate
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let workspace = opened else {
            return ["the store never opened the test workspace"]
        }
        print("store:  \(workspace.root)")

        guard let node = store.openBrowser(url: pageURL, title: "Under test", reveal: false) else {
            return ["the store refused to open a browser at \(pageURL)"]
        }
        print("node:   \(node.shortID) \(node.url)")
        // The engine loads asynchronously; the tools below would otherwise read
        // a page that has not arrived.
        for _ in 0..<80 where store.browsers.session(for: node.id)?.pageTitle == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The page's own title should have been written back onto the node, so
        // the header and the sidebar say what the page says.
        let onBoard = store.activeWorkspace?.browsers.first { $0.id == node.id }
        print("board title: \(onBoard?.pageTitle ?? "nil")")
        if onBoard?.pageTitle != "Meshvy browser test" {
            failures.append("the node did not learn the page title (\(onBoard?.pageTitle ?? "nil"))")
        }

        func call(_ op: String, _ extra: [String: Any] = [:]) async -> BrowserBridge.Response? {
            let id = UUID().uuidString.prefix(12).lowercased()
            var payload: [String: Any] = ["id": String(id), "op": op]
            payload.merge(extra) { _, new in new }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            let directory = BrowserBridge.requestsDirectory(for: workspace)
            // Written then renamed, exactly as the MCP server does it.
            let part = URL(fileURLWithPath: directory + "/\(id).part")
            try? data.write(to: part)
            try? FileManager.default.moveItem(
                at: part, to: URL(fileURLWithPath: directory + "/\(id).json")
            )

            let answer = URL(fileURLWithPath: BrowserBridge.responsesDirectory(for: workspace) + "/\(id).json")
            for _ in 0..<120 {
                if let body = try? Data(contentsOf: answer),
                   let decoded = try? JSONDecoder().decode(BrowserBridge.Response.self, from: body) {
                    try? FileManager.default.removeItem(at: answer)
                    return decoded
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        if let listed = await call("list") {
            print("list:   \(listed.result ?? listed.error ?? "-")")
            if listed.result?.contains(node.shortID) != true { failures.append("browser_list did not name the node") }
        } else {
            failures.append("browser_list was never answered")
        }

        if let snapshot = await call("snapshot") {
            print("snap:   \(String((snapshot.result ?? snapshot.error ?? "-").prefix(80)))")
            if snapshot.result?.contains("Meshvy browser test") != true {
                failures.append("browser_snapshot did not return the page: \(snapshot.error ?? "-")")
            }
            if snapshot.result?.contains("#go") != true {
                failures.append("browser_snapshot did not return selectors")
            }
        } else {
            failures.append("browser_snapshot was never answered")
        }

        if let clicked = await call("click", ["selector": "#go"]) {
            print("click:  \(clicked.result ?? clicked.error ?? "-")")
            if !clicked.ok { failures.append("browser_click failed: \(clicked.error ?? "-")") }
        } else {
            failures.append("browser_click was never answered")
        }

        if let evaluated = await call("eval", ["js": "return document.getElementById('state').textContent"]) {
            print("eval:   \(evaluated.result ?? evaluated.error ?? "-")")
            if evaluated.result != "clicked" { failures.append("the click did not land through the bridge") }
        } else {
            failures.append("browser_eval was never answered")
        }

        if let console = await call("console") {
            if console.result?.contains("deliberate console error") != true {
                failures.append("browser_console did not return the page's errors")
            }
        } else {
            failures.append("browser_console was never answered")
        }

        if let shot = await call("screenshot") {
            print("shot:   \(shot.result ?? shot.error ?? "-")")
            // "Wrote <path> — read it with…"; the path is the second word.
            let path = (shot.result ?? "").split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if !FileManager.default.fileExists(atPath: path) {
                failures.append("browser_screenshot did not leave a file behind")
            }
        } else {
            failures.append("browser_screenshot was never answered")
        }

        // A tool call naming a browser that is not there has to come back as a
        // refusal rather than hanging, which is what an agent would see.
        if let missing = await call("snapshot", ["node": "nope"]) {
            if missing.ok { failures.append("an unknown node was not refused") }
        } else {
            failures.append("an unknown node left the call unanswered")
        }

        if let session = store.browsers.session(for: node.id) {
            failures += checkCanvas(session: session)
        }

        store.closeBrowser(node.id)
        store.deleteWorkspace(workspace.id, removeWorktrees: true, force: true)
        try? await Task.sleep(for: .milliseconds(400))
        return failures
    }

    // MARK: - The canvas

    /// The container a browser node is drawn in.
    ///
    /// A browser magnifies by scaling its container's coordinate system — the
    /// same trick the terminals use, so the page keeps laying out at its own
    /// width while the board zooms, and a site under test is not reflowed every
    /// time someone scrolls. Worth checking against a real `WKWebView` rather
    /// than assuming what works for a terminal works here.
    private static func checkCanvas(session: BrowserSession) -> [String] {
        var failures: [String] = []
        let container = FlippedContainer()
        container.addSubview(session.surface)

        // 800×500 of board, drawn at half zoom: 400×250 on screen, and the page
        // still laid out at 800×500.
        container.scale = 0.5
        container.frame = CGRect(x: 0, y: 0, width: 400, height: 250)
        container.layoutSubtreeIfNeeded()
        print("canvas: page \(Int(session.surface.frame.width))×\(Int(session.surface.frame.height)) "
            + "in \(Int(container.frame.width))×\(Int(container.frame.height)) on screen")
        if abs(session.surface.frame.width - 800) > 1 || abs(session.surface.frame.height - 500) > 1 {
            failures.append("at half zoom the page laid out at \(session.surface.frame.size), not 800×500")
        }
        if abs(container.bounds.width - 800) > 1 {
            failures.append("the container's own bounds did not scale (\(container.bounds.size))")
        }

        // At 100% the two agree.
        container.scale = 1
        container.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        container.layoutSubtreeIfNeeded()
        if abs(session.surface.frame.width - 640) > 1 {
            failures.append("at 100% the page laid out at \(session.surface.frame.size), not 640×400")
        }

        session.surface.removeFromSuperview()
        return failures
    }

    /// One newline-delimited JSON message, the framing MCP's stdio transport uses.
    private static func readLine(from pipe: Pipe, timeout: TimeInterval) -> [String: Any]? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { usleep(20_000); continue }
            buffer.append(chunk)
            guard let newline = buffer.firstIndex(of: 0x0A) else { continue }
            let line = buffer[buffer.startIndex..<newline]
            return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
        return nil
    }
}

/// A one-page web server for the test, so the engine is checked against real
/// HTTP rather than a `file://` URL that behaves differently.
@MainActor
enum LocalPage {
    struct Handle {
        var url: String
        private let process: Process
        init(url: String, process: Process) {
            self.url = url
            self.process = process
        }
        func stop() { if process.isRunning { process.terminate() } }
    }

    static func start(in directory: String) -> Handle? {
        let port = Int.random(in: 42_000...42_999)
        try? page.write(toFile: directory + "/index.html", atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Wait for it to accept connections rather than racing the first load.
        let url = "http://127.0.0.1:\(port)/index.html"
        for _ in 0..<50 {
            if (try? Data(contentsOf: URL(string: url)!)) != nil {
                return Handle(url: url, process: process)
            }
            usleep(100_000)
        }
        process.terminate()
        return nil
    }

    /// Logs on load, throws on purpose, and has one button and one field whose
    /// handlers only fire for events a real interaction would produce.
    private static let page = """
    <!doctype html>
    <html>
      <head><meta charset="utf-8"><title>Meshvy browser test</title></head>
      <body>
        <h1>Meshvy browser test</h1>
        <p>Button state: <span id="state">not clicked</span></p>
        <p>Field echo: <span id="echo">empty</span></p>
        <button id="go">Run it</button>
        <input id="name" name="name" placeholder="your name">
        <a href="#somewhere">A link</a>
        <script>
          console.log('hello from the page');
          console.error('deliberate console error');
          document.getElementById('go').addEventListener('click', function () {
            document.getElementById('state').textContent = 'clicked';
          });
          document.getElementById('name').addEventListener('input', function (event) {
            document.getElementById('echo').textContent = event.target.value;
          });
          setTimeout(function () { throw new Error('thrown on purpose'); }, 50);
        </script>
      </body>
    </html>
    """
}
