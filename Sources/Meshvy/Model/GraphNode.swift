import CoreGraphics
import Foundation

/// Stable identity for anything placeable on the canvas. Node ids are also the
/// keys used by the saved layout, so they must not change between launches.
enum NodeID: Hashable, Codable {
    case session(String)
    /// A repository, by its checkout path. It is never a node of its own — the
    /// workspace node carries a chip for it — so this only ever names what is
    /// selected: its changes in the inspector.
    case worktree(String)
    case terminal(UUID)
    case workspace(UUID)
    case subAgent(String)
    case browser(UUID)

    var storageKey: String {
        switch self {
        case .session(let id): return "s:" + id
        case .worktree(let path): return "w:" + path
        case .terminal(let id): return "t:" + id.uuidString
        case .workspace(let id): return "k:" + id.uuidString
        case .subAgent(let id): return "a:" + id
        case .browser(let id): return "b:" + id.uuidString
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("s:") { self = .session(String(storageKey.dropFirst(2))) }
        else if storageKey.hasPrefix("w:") { self = .worktree(String(storageKey.dropFirst(2))) }
        else if storageKey.hasPrefix("t:"), let id = UUID(uuidString: String(storageKey.dropFirst(2))) {
            self = .terminal(id)
        } else if storageKey.hasPrefix("k:"), let id = UUID(uuidString: String(storageKey.dropFirst(2))) {
            self = .workspace(id)
        } else if storageKey.hasPrefix("a:") {
            self = .subAgent(String(storageKey.dropFirst(2)))
        } else if storageKey.hasPrefix("b:"), let id = UUID(uuidString: String(storageKey.dropFirst(2))) {
            self = .browser(id)
        } else { return nil }
    }
}

enum NodeKind {
    case session(SessionSummary, status: SessionStatus, live: LiveSession?)
    case terminal(TerminalNode)
    /// The parent node: the workspace itself, hosting its orchestrator.
    case workspace(Workspace)
    /// A sub-agent the orchestrator dispatched with the Agent tool.
    case subAgent(SubAgent)
    /// A browser showing the running application, drivable by an agent.
    case browser(BrowserNode)
}

struct CanvasNode: Identifiable {
    var id: NodeID
    var kind: NodeKind
    /// Top-left in world coordinates.
    var position: CGPoint
    var size: CGSize
    /// Section this node belongs to.
    var sectionID: String?
    /// Repository this node belongs to.
    var repoID: String?
    /// True when the user has dragged this node; auto-layout then leaves it alone.
    var isPinned: Bool = false

    var frame: CGRect { CGRect(origin: position, size: size) }

    var searchText: String {
        switch kind {
        case .session(let s, _, let live):
            return [s.displayTitle, s.resolvedPath, s.gitBranch, s.model, live?.name, s.id]
                .compactMap { $0 }.joined(separator: " ").lowercased()
        case .terminal(let t):
            return [t.title, t.cwd, t.role.label].joined(separator: " ").lowercased()
        case .workspace(let w):
            return ([w.name, w.branch] + w.repos.map(\.name)).joined(separator: " ").lowercased()
        case .subAgent(let a):
            return [a.title, a.kind, a.prompt].joined(separator: " ").lowercased()
        case .browser(let b):
            return [b.title, b.url, b.pageTitle].compactMap { $0 }.joined(separator: " ").lowercased()
        }
    }

    var sortDate: Date {
        switch kind {
        case .session(let s, _, _): return s.lastActivityAt
        case .terminal(let t): return t.createdAt
        case .workspace(let w): return w.createdAt
        case .subAgent(let a): return a.startedAt ?? .distantPast
        case .browser(let b): return b.createdAt
        }
    }
}

/// A relationship drawn on the edge layer.
struct CanvasEdge: Identifiable {
    enum Kind {
        /// A session ran in one of the workspace's repositories.
        case ranIn
        /// A terminal opened by hand in one of the workspace's repositories.
        case owns
        /// The orchestrator dispatched this agent.
        case dispatched
        /// A browser is pointed at what the workspace is running.
        case watches
    }

    var from: NodeID
    var to: NodeID
    var isLive: Bool
    var kind: Kind = .ranIn
    var id: String { from.storageKey + "->" + to.storageKey }
}



/// What the canvas renders for the current filter + layout state.
struct CanvasGraph {
    var nodes: [CanvasNode] = []
    var edges: [CanvasEdge] = []

    func node(_ id: NodeID) -> CanvasNode? { nodes.first { $0.id == id } }

    var contentRect: CGRect? { CGRect.bounding(nodes.map(\.frame)) }
}
