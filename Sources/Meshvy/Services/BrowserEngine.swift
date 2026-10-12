import AppKit
import Observation
import WebKit

/// One line the page logged, or threw.
struct ConsoleEntry: Identifiable, Hashable {
    enum Level: String {
        case log, info, warn, error

        var isProblem: Bool { self == .error || self == .warn }
    }

    var id = UUID()
    var level: Level
    var text: String
    var at: Date = Date()
}

/// One running browser, owned by the registry rather than by a SwiftUI view.
///
/// Same reason as `TerminalSession`: the canvas rebuilds node views on every pan
/// and zoom, and a `WKWebView` created in `makeNSView` would reload the page
/// each time. The web view is made once here and handed back on each render.
///
/// Everything an agent can ask the page to do lands on this class — see
/// `BrowserBridge` for how the tool calls get here.
@MainActor
@Observable
final class BrowserSession: NSObject, Identifiable {
    let id: UUID
    @ObservationIgnored let view: WKWebView
    /// Type-erased handle for view code.
    @ObservationIgnored var surface: NSView { view }

    private(set) var url: String
    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Last navigation failure, shown on the card. Cleared by the next load.
    private(set) var loadError: String?
    /// What the page has logged, newest last. Capped — a chatty app would
    /// otherwise grow this without bound for as long as the board is open.
    private(set) var console: [ConsoleEntry] = []
    /// A still of the page, for the one place the live view cannot be drawn:
    /// an `ImageRenderer` pass has no window, and `WKWebView` draws nothing
    /// without one. Only `--snapshot` fills this in.
    private(set) var poster: NSImage?

    /// Called when the URL or title changes, so the board can persist them.
    @ObservationIgnored var onPageChange: ((_ url: String, _ title: String?) -> Void)?

    /// Receives the page's console messages. Held by the content controller, so
    /// it points back at the session weakly.
    @ObservationIgnored private let relay = Relay()
    /// What the web view itself reports. Kept alive for the session's lifetime.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private static let consoleLimit = 400

    init(id: UUID, url: String) {
        self.id = id
        self.url = url

        // Everything has to be on the configuration *before* the web view is
        // made: `WKWebView` copies it at init and ignores later changes, so a
        // user script or message handler added afterwards is simply dropped.
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: BrowserScripts.consoleBridge,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.add(relay, name: "meshvy")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // The default store, so a dev server you have signed into stays signed
        // in between launches — the same browser you would have used by hand.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Lets the user open Web Inspector on the page, exactly as they would in
        // Safari. Harmless when the developer menu is off.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 620), configuration: configuration
        )
        super.init()

        relay.session = self
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.setValue(false, forKey: "drawsBackground")
        observe()

        if !url.isEmpty { load(url) }
    }

    /// The navigation delegate says when a load starts and ends; it does not say
    /// what the page turned out to be. `title` in particular is filled in after
    /// `didFinish` — waiting on the delegate for it leaves every card named
    /// after its host — and a single-page app changes all of these without
    /// navigating at all. So the web view's own properties are observed.
    private func observe() {
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncNavigationState() }
            },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncNavigationState() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    self?.isLoading = webView.isLoading
                    self?.syncNavigationState()
                }
            }
        ]
    }

    // MARK: - Driving

    @discardableResult
    func load(_ raw: String) -> Bool {
        guard let normalized = BrowserNode.normalize(raw), let target = URL(string: normalized) else {
            return false
        }
        loadError = nil
        url = normalized
        if target.isFileURL {
            view.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: target))
        }
        return true
    }

    func reload() {
        loadError = nil
        // A dev server that was down when the page first loaded has no back/
        // forward history to reload from, so re-issue the request instead.
        if view.url == nil { load(url) } else { view.reloadFromOrigin() }
    }

    func goBack() { view.goBack() }
    func goForward() { view.goForward() }
    func stop() { view.stopLoading() }

    func clearConsole() { console = [] }

    /// Runs the agent's own JavaScript in the page and returns it as text.
    ///
    /// `callAsyncJavaScript` rather than `evaluateJavaScript` so the snippet can
    /// `await` and `return`, which is what anything interesting needs.
    func evaluate(_ javaScript: String) async throws -> String {
        let value = try await view.callAsyncJavaScript(
            javaScript, arguments: [:], in: nil, contentWorld: .page
        )
        return BrowserSession.describe(value)
    }

    /// Runs one of Meshvy's own snippets, which all return a JSON string.
    private func runInternal(_ javaScript: String) async throws -> Any {
        let value = try await view.callAsyncJavaScript(
            javaScript, arguments: [:], in: nil, contentWorld: .page
        )
        guard let text = value as? String, let data = text.data(using: .utf8) else {
            throw BrowserError.message("the page did not answer")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// What the page says it is: title, readable text, and every control worth
    /// clicking with a selector that addresses it.
    func snapshot(maxCharacters: Int = 6000) async throws -> PageSnapshot {
        guard let root = try await runInternal(BrowserScripts.snapshot) as? [String: Any] else {
            throw BrowserError.message("could not read the page")
        }
        let elements = (root["elements"] as? [[String: Any]] ?? []).map { entry in
            PageSnapshot.Element(
                role: entry["role"] as? String ?? "element",
                label: entry["label"] as? String ?? "",
                selector: entry["selector"] as? String ?? "",
                value: entry["value"] as? String,
                isDisabled: entry["disabled"] as? Bool ?? false
            )
        }
        var text = root["text"] as? String ?? ""
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "\n… truncated"
        }
        return PageSnapshot(
            url: root["url"] as? String ?? url,
            title: root["title"] as? String,
            text: text,
            elements: elements
        )
    }

    func click(selector: String) async throws -> String {
        try await act(BrowserScripts.click, selector: selector)
    }

    func type(selector: String, text: String, submit: Bool) async throws -> String {
        try await act(BrowserScripts.type, selector: selector, text: text, submit: submit)
    }

    /// Waits for text to appear, or a selector to match. Polls in the page
    /// rather than in Swift so a single-page app that re-renders is caught.
    func waitFor(text: String?, selector: String?, timeout: TimeInterval) async throws -> String {
        guard text?.isEmpty == false || selector?.isEmpty == false else {
            throw BrowserError.message("browser_wait_for needs text or a selector")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                return try await act(
                    BrowserScripts.probe, selector: selector ?? "", text: text ?? "", submit: false
                )
            } catch {
                // "not yet" is the page saying to keep waiting. Anything else —
                // a selector that will never parse, say — is worth answering
                // now rather than at the end of the timeout.
                guard error.localizedDescription == BrowserSession.notYet else { throw error }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw BrowserError.message("timed out after \(Int(timeout))s")
    }

    /// What one poll of a wait reports when the page is not there yet.
    static let notYet = "not yet"

    private func act(
        _ script: String, selector: String, text: String = "", submit: Bool = false
    ) async throws -> String {
        let payload: [String: Any] = ["selector": selector, "text": text, "submit": submit]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let arguments = String(decoding: data, as: UTF8.self)
        guard let root = try await runInternal("const ARGS = \(arguments);\n" + script) as? [String: Any]
        else { throw BrowserError.message("the page did not answer") }
        if let error = root["error"] as? String { throw BrowserError.message(error) }
        return root["ok"] as? String ?? "done"
    }

    /// PNG of the visible page, for an agent that wants to look at it.
    func screenshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await view.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw BrowserError.message("could not encode the screenshot") }
        return png
    }

    /// Takes the still the documentation renderer draws in place of the page.
    ///
    /// `takeSnapshot` returns an empty image for a view that is not in a
    /// window, so the surface is parked in an offscreen one for the length of
    /// the capture and handed straight back — the canvas may be showing it.
    func capturePoster(size: CGSize) async {
        let parent = surface.superview
        let frame = surface.frame
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(surface)
        surface.frame = CGRect(origin: .zero, size: size)
        defer {
            surface.removeFromSuperview()
            if let parent { parent.addSubview(surface); surface.frame = frame }
        }

        // One runloop turn for the resize to lay out before the camera.
        try? await Task.sleep(for: .milliseconds(400))
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        poster = try? await view.takeSnapshot(configuration: configuration)
    }

    // MARK: - Internals

    private func record(_ entry: ConsoleEntry) {
        console.append(entry)
        if console.count > BrowserSession.consoleLimit {
            console.removeFirst(console.count - BrowserSession.consoleLimit)
        }
    }

    private func syncNavigationState() {
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
        if let current = view.url?.absoluteString, current != "about:blank" { url = current }
        let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        pageTitle = (title?.isEmpty == false) ? title : nil
        onPageChange?(url, pageTitle)
    }

    /// `Any?` from JavaScript, as something an agent can read.
    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let text as String: return text
        case let number as NSNumber:
            // `true` arrives as an NSNumber too, and "1" is not what was meant.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            guard let value,
                  JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(
                      withJSONObject: value, options: [.prettyPrinted, .sortedKeys]
                  )
            else { return String(describing: value ?? "null") }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Holds the message handler, so the content controller does not retain the
    /// session that owns it.
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var session: BrowserSession?

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let text = body["text"] as? String else { return }
            let level = ConsoleEntry.Level(rawValue: body["level"] as? String ?? "log") ?? .log
            MainActor.assumeIsolated {
                session?.record(ConsoleEntry(level: level, text: String(text.prefix(2000))))
            }
        }
    }

    enum BrowserError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }
}

// MARK: - Navigation

extension BrowserSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        loadError = error.localizedDescription
        syncNavigationState()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        isLoading = false
        // A dev server that is not up yet is the single most likely failure
        // here, so say that rather than "could not connect to the server".
        loadError = (error as NSError).code == NSURLErrorCannotConnectToHost
            ? "Nothing is listening on \(URL(string: url)?.host ?? "that host") yet"
            : error.localizedDescription
        syncNavigationState()
    }

    /// `target="_blank"` has nowhere to go on a canvas, so it loads in place
    /// rather than silently doing nothing.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let target = navigationAction.request.url { webView.load(URLRequest(url: target)) }
        return nil
    }

    /// A dev server with a self-signed certificate is normal; anything else
    /// keeps the usual refusal.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              BrowserSession.isLocal(challenge.protectionSpace.host)
        else { return completionHandler(.performDefaultHandling, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func isLocal(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

/// What the page looks like, in the shape an agent reads it.
struct PageSnapshot {
    struct Element {
        var role: String
        var label: String
        var selector: String
        var value: String?
        var isDisabled: Bool
    }

    var url: String
    var title: String?
    var text: String
    var elements: [Element]

    /// Formatted for a tool result: the selectors are quoted exactly as
    /// `browser_click` wants them back.
    var transcript: String {
        var lines = ["# \(title ?? "Untitled")", url, ""]
        if !text.isEmpty {
            lines.append("## Page text")
            lines.append(text)
            lines.append("")
        }
        if !elements.isEmpty {
            lines.append("## Controls — pass the selector to browser_click / browser_type")
            for element in elements.prefix(120) {
                var line = "- \(element.role): \(element.label.isEmpty ? "—" : element.label)"
                if let value = element.value, !value.isEmpty { line += "  [value: \(value)]" }
                if element.isDisabled { line += "  [disabled]" }
                line += "\n    selector: \(element.selector)"
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Holds every live browser, keyed by its node id.
@MainActor
@Observable
final class BrowserRegistry {
    private var sessions: [UUID: BrowserSession] = [:]

    func session(for id: UUID) -> BrowserSession? { sessions[id] }

    @discardableResult
    func start(node: BrowserNode) -> BrowserSession {
        if let existing = sessions[node.id] { return existing }
        let session = BrowserSession(id: node.id, url: node.url)
        sessions[node.id] = session
        return session
    }

    func discard(_ id: UUID) {
        sessions[id]?.stop()
        sessions[id] = nil
    }
}
