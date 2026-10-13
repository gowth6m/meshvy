import AppKit
import BrowserKit
import Foundation
import MeshvyModels

// Browser nodes and the tools an agent drives them with.
extension MeshvyStore {
    // MARK: - Browsers
    //
    // A workspace is repositories plus agents, but what the agents are building
    // is a running application — and until there was a browser on the board, the
    // only way to look at one was to leave Meshvy. A browser node is a real page
    // on the canvas: the person watches it, and the agent drives it through the
    // `browser_*` tools. See `BrowserBridge`.

    /// Puts a browser on the board. Reuses one already pointed at the same host
    /// and port rather than stacking a second node on top of it.
    @discardableResult
    public func openBrowser(
        url: String = "",
        title: String? = nil,
        repoID: String? = nil,
        bridgeID: String? = nil,
        reveal shouldReveal: Bool = true
    ) -> BrowserNode? {
        guard var workspace = activeWorkspace else { return nil }

        // Empty is the menu item: a blank node whose address bar is the prompt.
        // Every agent-driven path arrives here with a URL.
        var target = ""
        var origin: String?
        if !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = BrowserNode.normalize(url) else {
                show(.init(kind: .failure, title: "That is not a URL Meshvy can open", detail: url))
                return nil
            }
            target = normalized
            origin = URLComponents(string: normalized).flatMap { components -> String? in
                guard let host = components.host else { return nil }
                return host + (components.port.map { ":\($0)" } ?? "")
            }
        }
        if let origin, let existing = workspace.browsers.first(where: { $0.origin == origin }) {
            navigateBrowser(existing.id, to: target)
            if shouldReveal { reveal(.browser(existing.id)) }
            return activeWorkspace?.browsers.first { $0.id == existing.id }
        }

        var node = BrowserNode(
            title: title ?? (origin ?? "Browser"),
            url: target,
            repoID: repoID,
            bridgeID: bridgeID,
            hasFixedTitle: title != nil
        )
        node.size = CGSize(width: 880, height: 600)
        browsers.start(node: node)
        bindBrowser(node.id)
        workspace.browsers.append(node)
        update(workspace)
        if shouldReveal {
            selection = .browser(node.id)
            reveal(.browser(node.id))
        }
        return node
    }

    /// Mounts the engine for a node restored from a saved board, so an agent can
    /// address it before anyone has looked at it.
    public func ensureBrowserRunning(_ id: UUID) -> BrowserSession? {
        guard let node = activeWorkspace?.browsers.first(where: { $0.id == id }) else { return nil }
        let session = browsers.session(for: id) ?? browsers.start(node: node)
        bindBrowser(id)
        return session
    }

    /// Writes the page's own URL and title back onto the node, so the board
    /// reopens where it was left and the header says what the page says.
    func bindBrowser(_ id: UUID) {
        guard let session = browsers.session(for: id), session.onPageChange == nil else { return }
        session.onPageChange = { [weak self] url, pageTitle in
            guard let self, var workspace = self.activeWorkspace,
                  let index = workspace.browsers.firstIndex(where: { $0.id == id }) else { return }
            let node = workspace.browsers[index]
            guard node.url != url || node.pageTitle != pageTitle else { return }
            workspace.browsers[index].url = url
            workspace.browsers[index].pageTitle = pageTitle
            if !node.hasFixedTitle, let pageTitle, !pageTitle.isEmpty {
                workspace.browsers[index].title = pageTitle
            }
            self.update(workspace)
        }
    }

    public func navigateBrowser(_ id: UUID, to url: String) {
        guard var workspace = activeWorkspace,
              let index = workspace.browsers.firstIndex(where: { $0.id == id }),
              let target = BrowserNode.normalize(url) else { return }
        workspace.browsers[index].url = target
        update(workspace)
        _ = ensureBrowserRunning(id)?.load(target)
    }

    public func reloadBrowser(_ id: UUID) { ensureBrowserRunning(id)?.reload() }

    public func closeBrowser(_ id: UUID) {
        browsers.discard(id)
        guard var workspace = activeWorkspace else { return }
        workspace.browsers.removeAll { $0.id == id }
        update(workspace)
        if selection == .browser(id) { selection = nil }
    }

    public func moveBrowser(_ id: UUID, to position: CGPoint, size: CGSize? = nil) {
        guard var workspace = activeWorkspace,
              let index = workspace.browsers.firstIndex(where: { $0.id == id }) else { return }
        workspace.browsers[index].position = position
        if let size { workspace.browsers[index].size = size }
        workspaces[workspaces.firstIndex { $0.id == workspace.id }!] = workspace
        if let node = graph.nodes.firstIndex(where: { $0.id == .browser(id) }) {
            graph.nodes[node].position = position
            if let size { graph.nodes[node].size = size }
            graph.nodes[node].kind = .browser(workspace.browsers[index])
        }
    }

    // MARK: - Browser tools
    //
    // Everything below answers a `browser_*` tool call. Each one is a file the
    // MCP server dropped and is blocking on, so every path must write exactly
    // one answer back — including the failures.

    func drainBrowserBridge() {
        guard let workspace = activeWorkspace else { return }
        for (url, request) in BrowserBridge.pendingRequests(for: workspace) {
            // Removed first: a request that throws must not be retried forever.
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor [weak self] in await self?.serve(request, in: workspace) }
        }
    }

    func serve(_ request: BrowserBridge.Request, in workspace: Workspace) async {
        do {
            let result = try await perform(request)
            BrowserBridge.answer(
                .init(id: request.id, ok: true, result: result, error: nil), in: workspace
            )
        } catch {
            BrowserBridge.answer(
                .init(id: request.id, ok: false, result: nil, error: error.localizedDescription),
                in: workspace
            )
        }
    }

    func perform(_ request: BrowserBridge.Request) async throws -> String {
        guard let workspace = activeWorkspace else {
            throw BrowserSession.BrowserError.message("no workspace is open in Meshvy")
        }

        switch request.op {
        case "open":
            guard let url = request.url else {
                throw BrowserSession.BrowserError.message("browser_open needs a url")
            }
            guard let node = openBrowser(url: url, title: request.title, bridgeID: request.node) else {
                throw BrowserSession.BrowserError.message("could not open \(url)")
            }
            return "Opened browser \(node.shortID) at \(node.url). "
                + "Pass node: \"\(node.shortID)\" to the other browser tools, or omit it while this is the only one."

        case "list":
            guard !workspace.browsers.isEmpty else { return "No browser nodes on the board yet." }
            return workspace.browsers.map { node in
                let session = browsers.session(for: node.id)
                let state = session?.isLoading == true ? "loading" : (session == nil ? "idle" : "loaded")
                let problems = session?.console.filter { $0.level == .error }.count ?? 0
                return "\(node.shortID)  \(state)  \(node.url)"
                    + (node.pageTitle.map { "  — \($0)" } ?? "")
                    + (problems > 0 ? "  [\(problems) console errors]" : "")
            }.joined(separator: "\n")

        case "close":
            let node = try resolve(request.node, in: workspace)
            closeBrowser(node.id)
            return "Closed browser \(node.shortID)."

        default:
            break
        }

        let node = try resolve(request.node, in: workspace)
        guard let session = ensureBrowserRunning(node.id) else {
            throw BrowserSession.BrowserError.message("browser \(node.shortID) is not running")
        }

        // What the page logs from here on is this action's doing, and is worth
        // handing back with the result rather than waiting to be asked.
        let mark = session.console.count

        switch request.op {
        case "navigate":
            guard let url = request.url else {
                throw BrowserSession.BrowserError.message("browser_navigate needs a url")
            }
            navigateBrowser(node.id, to: url)
            try await settle(session)
            return "Loaded \(session.url)." + consoleTail(session, since: 0)

        case "snapshot":
            try await settle(session)
            return try await session.snapshot().transcript

        case "click":
            guard let selector = request.selector else {
                throw BrowserSession.BrowserError.message("browser_click needs a selector")
            }
            let outcome = try await session.click(selector: selector)
            try await settle(session)
            return outcome + consoleTail(session, since: mark)

        case "type":
            guard let selector = request.selector, let text = request.text else {
                throw BrowserSession.BrowserError.message("browser_type needs a selector and text")
            }
            let outcome = try await session.type(
                selector: selector, text: text, submit: request.submit ?? false
            )
            try await settle(session)
            return outcome + consoleTail(session, since: mark)

        case "eval":
            guard let javaScript = request.js else {
                throw BrowserSession.BrowserError.message("browser_eval needs js")
            }
            return try await session.evaluate(javaScript)

        case "console":
            let limit = max(1, min(request.limit ?? 40, 200))
            let lines = session.console.suffix(limit)
            guard !lines.isEmpty else { return "The page has logged nothing." }
            return lines.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")

        case "screenshot":
            let data = try await session.screenshot()
            let directory = BrowserBridge.shotsDirectory(for: workspace)
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = directory + "/\(node.shortID)-\(Int(Date().timeIntervalSince1970)).png"
            try data.write(to: URL(fileURLWithPath: path))
            return "Wrote \(path) — read it with the Read tool."

        case "wait":
            let timeout = Double(max(500, min(request.timeoutMs ?? 10_000, 120_000))) / 1000
            return try await session.waitFor(
                text: request.text, selector: request.selector, timeout: timeout
            )

        case "reload":
            session.reload()
            try await settle(session)
            return "Reloaded \(session.url)." + consoleTail(session, since: 0)

        case "back":
            guard session.canGoBack else {
                throw BrowserSession.BrowserError.message("nothing to go back to")
            }
            session.goBack()
            try await settle(session)
            return "Back at \(session.url)."

        default:
            throw BrowserSession.BrowserError.message("unknown browser op “\(request.op)”")
        }
    }

    /// Which browser a tool call means. One on the board needs no saying; more
    /// than one and the answer lists them rather than guessing.
    func resolve(_ hint: String?, in workspace: Workspace) throws -> BrowserNode {
        if let hint, !hint.isEmpty {
            let needle = hint.lowercased()
            if let match = workspace.browsers.first(where: {
                $0.shortID == needle || $0.id.uuidString.lowercased() == needle
                    || $0.bridgeID?.lowercased() == needle
                    || $0.title.lowercased() == needle
            }) { return match }
            throw BrowserSession.BrowserError.message(
                "no browser “\(hint)” on the board. Open one with browser_open, "
                    + "or call browser_list to see them."
            )
        }
        switch workspace.browsers.count {
        case 0:
            throw BrowserSession.BrowserError.message(
                "there is no browser on the board — call browser_open with a url first"
            )
        case 1:
            return workspace.browsers[0]
        default:
            let ids = workspace.browsers.map { "\($0.shortID) (\($0.url))" }.joined(separator: ", ")
            throw BrowserSession.BrowserError.message(
                "there are \(workspace.browsers.count) browsers on the board — pass node: one of \(ids)"
            )
        }
    }

    /// Gives a navigation a moment to land, so a snapshot taken straight after a
    /// click reads the page that click produced rather than the one before it.
    func settle(_ session: BrowserSession, within seconds: Double = 8) async throws {
        try? await Task.sleep(for: .milliseconds(120))
        let deadline = Date().addingTimeInterval(seconds)
        while session.isLoading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Errors the page threw while we were acting on it, counted from `since`
    /// so a click is not blamed for what the page logged on load. Attached to
    /// the result because that is the moment they matter, and an agent that has
    /// to ask twice usually does not ask at all. A navigation passes 0: it
    /// cleared the console's relevance anyway.
    func consoleTail(_ session: BrowserSession, since mark: Int, limit: Int = 10) -> String {
        let problems = session.console.dropFirst(mark).filter { $0.level.isProblem }.suffix(limit)
        guard !problems.isEmpty else { return "" }
        return "\n\nThe page logged:\n"
            + problems.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n")
    }
}
