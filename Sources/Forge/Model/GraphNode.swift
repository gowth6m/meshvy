import CoreGraphics
import Foundation

/// Stable identity for anything placeable on the canvas. Node ids are also the
/// keys used by the saved layout, so they must not change between launches.
enum NodeID: Hashable, Codable {
    case session(String)
    case worktree(String)
    case terminal(UUID)

    var storageKey: String {
        switch self {
        case .session(let id): return "s:" + id
        case .worktree(let path): return "w:" + path
        case .terminal(let id): return "t:" + id.uuidString
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("s:") { self = .session(String(storageKey.dropFirst(2))) }
        else if storageKey.hasPrefix("w:") { self = .worktree(String(storageKey.dropFirst(2))) }
        else if storageKey.hasPrefix("t:"), let id = UUID(uuidString: String(storageKey.dropFirst(2))) {
            self = .terminal(id)
        } else { return nil }
    }
}

enum NodeKind {
    case session(SessionSummary, status: SessionStatus, live: LiveSession?)
    case worktree(Worktree)
    case terminal(TerminalNode)
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
        case .worktree(let w):
            return [w.path, w.branch, w.lastCommitSubject].compactMap { $0 }.joined(separator: " ").lowercased()
        case .terminal(let t):
            return [t.title, t.cwd, t.role.label].joined(separator: " ").lowercased()
        }
    }

    var sortDate: Date {
        switch kind {
        case .session(let s, _, _): return s.lastActivityAt
        case .worktree(let w): return w.lastCommitDate ?? .distantPast
        case .terminal(let t): return t.createdAt
        }
    }
}

/// A relationship drawn on the edge layer.
struct CanvasEdge: Identifiable {
    enum Kind {
        /// A session ran in this checkout.
        case ranIn
        /// A terminal has this checkout under it.
        case owns
    }

    var from: NodeID
    var to: NodeID
    var isLive: Bool
    var kind: Kind = .ranIn
    var id: String { from.storageKey + "->" + to.storageKey }
}

/// Translucent container drawn behind the nodes of one section.
struct CanvasGroup: Identifiable {
    var id: String
    var kind: GroupKind
    var title: String
    var subtitle: String
    var rect: CGRect
    var seed: String
}

/// What the canvas renders for the current filter + layout state.
struct CanvasGraph {
    var nodes: [CanvasNode] = []
    var edges: [CanvasEdge] = []
    var groups: [CanvasGroup] = []

    func node(_ id: NodeID) -> CanvasNode? { nodes.first { $0.id == id } }

    var contentRect: CGRect? {
        CGRect.bounding(groups.map(\.rect) + nodes.map(\.frame))
    }
}
