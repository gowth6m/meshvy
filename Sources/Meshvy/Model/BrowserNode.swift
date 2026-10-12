import CoreGraphics
import Foundation

/// A browser placed on the canvas.
///
/// The point of a workspace is that the repositories are already checked out
/// and an agent is already running in each of them — but the thing those agents
/// are building is a *running application*, and until now the only way to look
/// at it was to leave Meshvy. A browser node puts the app on the board next to
/// the agent writing it, and gives the agent a way to drive it: see
/// `BrowserBridge` for the tools it gets.
///
/// Unlike a terminal, a browser node survives a quit. There is no process to
/// resurrect — just a URL — so a board reopens pointing where it was left.
struct BrowserNode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// What the header says. Replaced by the page's own title once it loads,
    /// unless an agent named it.
    var title: String
    /// Where it is pointed. Empty means the start page.
    var url: String
    /// Page title last reported by the engine, for the board and `browser_list`.
    var pageTitle: String?
    /// Repository whose application this is, when it was opened from one.
    var repoID: String?
    /// Set when an agent opened this through the bridge, so a tool call with no
    /// explicit target can address the one it made.
    var bridgeID: String?
    /// True when the header's name came from an agent and should not be
    /// overwritten by the page title.
    var hasFixedTitle: Bool = false
    var x: Double = 0
    var y: Double = 0
    var width: Double = 900
    var height: Double = 620
    var createdAt: Date = Date()

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set { width = newValue.width; height = newValue.height }
    }

    init(
        id: UUID = UUID(), title: String, url: String,
        repoID: String? = nil, bridgeID: String? = nil, hasFixedTitle: Bool = false
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.repoID = repoID
        self.bridgeID = bridgeID
        self.hasFixedTitle = hasFixedTitle
    }

    /// Lenient for the same reason as `Workspace`.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = fields.value(.id, or: UUID())
        title = fields.value(.title, or: "Browser")
        url = fields.value(.url, or: "")
        pageTitle = fields.optional(String.self, .pageTitle)
        repoID = fields.optional(String.self, .repoID)
        bridgeID = fields.optional(String.self, .bridgeID)
        hasFixedTitle = fields.value(.hasFixedTitle, or: false)
        x = fields.value(.x, or: 0)
        y = fields.value(.y, or: 0)
        width = fields.value(.width, or: 900)
        height = fields.value(.height, or: 620)
        createdAt = fields.value(.createdAt, or: Date())
    }

    /// How an agent addresses this node: short enough to type, long enough not
    /// to collide on a board of a few browsers.
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// Host and port, so opening the same dev server twice reuses one node.
    var origin: String? {
        guard let components = URLComponents(string: url), let host = components.host else { return nil }
        return host + (components.port.map { ":\($0)" } ?? "")
    }

    /// Host and path, for a header that has one line to work with.
    var displayURL: String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/" ? "" : components.path
        return host + port + path
    }

    /// Normalises what someone typed into something `WKWebView` will load.
    /// A bare `localhost:3000` is the common case and is not a search query.
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("/") { return "file://" + trimmed }
        // A dot or a port means they meant a host; anything else is a search.
        let head = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        if head.contains(".") || head.contains(":") { return "http://" + trimmed }
        var query = URLComponents(string: "https://duckduckgo.com/")
        query?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return query?.url?.absoluteString
    }
}
