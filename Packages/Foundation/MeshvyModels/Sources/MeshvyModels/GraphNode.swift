import CoreGraphics
import Foundation
import MeshvyCore

/// Stable identity for anything placeable on the canvas. Node ids are also the
/// keys used by the saved layout, so they must not change between launches.
public enum NodeID: Hashable, Codable {
    case session(String)
    /// A repository, by its checkout path. It is never a node of its own — the
    /// workspace node carries a chip for it — so this only ever names what is
    /// selected: its changes in the inspector.
    case worktree(String)
    case terminal(UUID)
    case workspace(UUID)
    case subAgent(String)
    case browser(UUID)

    public var storageKey: String {
        switch self {
        case .session(let id): return "s:" + id
        case .worktree(let path): return "w:" + path
        case .terminal(let id): return "t:" + id.uuidString
        case .workspace(let id): return "k:" + id.uuidString
        case .subAgent(let id): return "a:" + id
        case .browser(let id): return "b:" + id.uuidString
        }
    }

    public init?(storageKey: String) {
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

public enum NodeKind {
    case session(SessionSummary, status: SessionStatus, live: LiveSession?)
    case terminal(TerminalNode)
    /// The parent node: the workspace itself, hosting its orchestrator.
    case workspace(Workspace)
    /// A sub-agent the orchestrator dispatched with the Agent tool.
    case subAgent(SubAgent)
    /// A browser showing the running application, drivable by an agent.
    case browser(BrowserNode)
}

public struct CanvasNode: Identifiable {
    public var id: NodeID
    public var kind: NodeKind
    /// Top-left in world coordinates.
    public var position: CGPoint
    public var size: CGSize
    /// Section this node belongs to.
    public var sectionID: String?
    /// Repository this node belongs to.
    public var repoID: String?
    /// True when the user has dragged this node; auto-layout then leaves it alone.
    public var isPinned: Bool = false

    public init(
        id: NodeID,
        kind: NodeKind,
        position: CGPoint,
        size: CGSize,
        sectionID: String? = nil,
        repoID: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.size = size
        self.sectionID = sectionID
        self.repoID = repoID
        self.isPinned = isPinned
    }

    public var frame: CGRect { CGRect(origin: position, size: size) }

    /// Whether this node hosts a live AppKit view — a PTY or a web page.
    ///
    /// The distinction is the one the canvas keeps asking about, so it is
    /// answered here once rather than by a `switch` in each gesture. Live nodes
    /// are never unmounted, they keep their own clicks and keyboard focus, and
    /// their body is not something a drag may take hold of.
    public var hostsLiveContent: Bool {
        switch kind {
        case .terminal, .workspace, .browser: return true
        case .session, .subAgent: return false
        }
    }

    /// How much of this node's top is chrome rather than live content.
    ///
    /// It is the part the scroll wheel must not reach through on its way to a
    /// terminal's scrollback or a page, and the part a drag may always take
    /// hold of. One answer, derived from the same constants the views lay
    /// themselves out with, so the two can never disagree about where a node's
    /// own surface begins.
    public var chromeHeight: CGFloat {
        let rule = BoardMetrics.Chrome.rule
        switch kind {
        case .terminal(let terminal):
            // A plain shell draws no status strip: it has no agent to report.
            return terminal.sessionID == nil
                ? BoardMetrics.Chrome.header + rule
                : BoardMetrics.Chrome.header + rule + BoardMetrics.Chrome.statusStrip + rule
        case .workspace(let workspace):
            let top = BoardMetrics.Chrome.workspaceHeader + BoardMetrics.Chrome.repoStrip + rule
            // The strip only appears once something is running in the node.
            guard workspace.orchestrator != nil else { return top }
            return top + BoardMetrics.Chrome.statusStrip + rule
        case .browser:
            return BoardMetrics.Chrome.header + rule + BoardMetrics.Chrome.addressBar + rule
        case .session, .subAgent:
            // A card is all content; there is nothing live underneath to guard.
            return 0
        }
    }

    /// How small this node may be dragged. Every node is resizable, and no two
    /// kinds stop in the same place — see `BoardMetrics`.
    public var minimumSize: CGSize {
        switch kind {
        case .terminal: return BoardMetrics.minimumTerminal
        case .browser: return BoardMetrics.minimumBrowser
        case .workspace: return BoardMetrics.minimumWorkspace
        case .session, .subAgent: return BoardMetrics.minimumCard
        }
    }

    public var searchText: String {
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

    public var sortDate: Date {
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
public struct CanvasEdge: Identifiable {
    public enum Kind {
        /// A session ran in one of the workspace's repositories.
        case ranIn
        /// A terminal opened by hand in one of the workspace's repositories.
        case owns
        /// The orchestrator dispatched this agent.
        case dispatched
        /// A browser is pointed at what the workspace is running.
        case watches
        /// Drawn by hand: the source's work is context for the target.
        case feeds
    }

    public var from: NodeID
    public var to: NodeID
    public var isLive: Bool
    public var kind: Kind = .ranIn

    public init(
        from: NodeID,
        to: NodeID,
        isLive: Bool,
        kind: Kind = .ranIn
    ) {
        self.from = from
        self.to = to
        self.isLive = isLive
        self.kind = kind
    }
    public var id: String { from.storageKey + "->" + to.storageKey }
}

/// What the canvas renders for the current filter + layout state.
public struct CanvasGraph {
    public var nodes: [CanvasNode] = []
    public var edges: [CanvasEdge] = []

    public init(
        nodes: [CanvasNode] = [],
        edges: [CanvasEdge] = []
    ) {
        self.nodes = nodes
        self.edges = edges
    }

    public func node(_ id: NodeID) -> CanvasNode? { nodes.first { $0.id == id } }

    public var contentRect: CGRect? { CGRect.bounding(nodes.map(\.frame)) }
}
