import CoreGraphics
import Foundation
import MeshvyCore

/// A workspace is a set of worktrees — one per repository — all cut from the
/// same base on the same branch, living side by side under one folder.
///
/// That folder is the parent the orchestrator works from: the repositories are
/// literally its subdirectories, so an agent started there can see and change
/// all of them without any extra plumbing.
public struct Workspace: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    /// Branch checked out in every repository of this workspace.
    public var branch: String
    /// What the branch was cut from. Nil means each repo's own default branch.
    public var baseRef: String?
    /// `~/.meshvy/<slug>` — contains one subdirectory per repository.
    public var root: String
    public var repos: [WorkspaceRepo] = []
    /// The Claude Code session that sits on top of the whole workspace. It is
    /// hosted by the workspace node itself rather than floating separately.
    public var orchestrator: TerminalNode?
    /// Per-repo agents and plain shells, placed freely on the board.
    public var terminals: [TerminalNode] = []
    /// Browser nodes on the board — a page you can watch and an agent can drive.
    public var browsers: [BrowserNode] = []
    /// Links drawn by hand between two nodes. The composer derives every other
    /// edge from the shape of the workspace; these are the ones you decide.
    public var links: [WorkspaceLink] = []
    /// Size of the workspace node on the board while an orchestrator is
    /// running in it.
    public var boardWidth: Double = 780
    public var boardHeight: Double = 520
    /// Height it takes when nothing is running in it, where it shows a start
    /// prompt rather than a terminal. Its own field because the two states hold
    /// different things and want different room: resize the node you can see
    /// and it stays that size, without quietly rewriting the other one.
    public var idleBoardHeight: Double = Workspace.idleHeight
    public var createdAt: Date = Date()
    public var notes: String?
    /// Set when the workspace has been archived: the worktrees stay exactly
    /// where they are, it just leaves the board and the switcher. Decoded as
    /// nil for boards saved before archiving existed, which read as active.
    public var archivedAt: Date?

    public var readyRepos: [WorkspaceRepo] { repos.filter(\.isReady) }
    public var isArchived: Bool { archivedAt != nil }
    /// Every terminal on the board, orchestrator included.
    public var allTerminals: [TerminalNode] { (orchestrator.map { [$0] } ?? []) + terminals }
    /// Height the node collapses to when no orchestrator is running, before
    /// anyone has resized it.
    public static let idleHeight: Double = 186
    public var worktreePaths: [String] { readyRepos.map(\.worktreePath) }

    public static func root(for name: String) -> String {
        Workspace.meshvyHome + "/" + Workspace.slug(name)
    }

    /// Everything Meshvy creates lives here, out of the way of your own folders.
    public static var meshvyHome: String { NSHomeDirectory() + "/.meshvy" }

    /// Filesystem- and branch-safe form of a display name.
    public static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed
    }

    public init(
        id: UUID = UUID(), name: String, branch: String, baseRef: String? = nil, root: String
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.baseRef = baseRef
        self.root = root
    }

    /// Reads a board saved by any version of Meshvy. Only `name` and `root` are
    /// load-bearing; everything else fills in, so adding a field here never
    /// costs anyone the workspaces they already had.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = fields.value(.id, or: UUID())
        name = fields.value(.name, or: "Workspace")
        branch = fields.value(.branch, or: "main")
        baseRef = fields.optional(String.self, .baseRef)
        root = fields.value(.root, or: Workspace.meshvyHome + "/workspace")
        repos = fields.value(.repos, or: [])
        orchestrator = fields.optional(TerminalNode.self, .orchestrator)
        terminals = fields.value(.terminals, or: [])
        browsers = fields.value(.browsers, or: [])
        boardWidth = fields.value(.boardWidth, or: 780)
        boardHeight = fields.value(.boardHeight, or: 520)
        idleBoardHeight = fields.value(.idleBoardHeight, or: Workspace.idleHeight)
        createdAt = fields.value(.createdAt, or: Date())
        notes = fields.optional(String.self, .notes)
        archivedAt = fields.optional(Date.self, .archivedAt)
        links = fields.value(.links, or: [])
    }
}

/// A link drawn between two nodes: what the source is doing is context the
/// target should have.
///
/// Every other edge on the board is derived — a terminal owns the checkout it
/// runs in, the orchestrator dispatched the agent it spawned. This is the one
/// kind the board cannot work out for itself, so it is stored.
public struct WorkspaceLink: Codable, Hashable, Identifiable {
    public var from: NodeID
    public var to: NodeID
    public var createdAt: Date = Date()

    public init(
        from: NodeID,
        to: NodeID,
        createdAt: Date = Date()
    ) {
        self.from = from
        self.to = to
        self.createdAt = createdAt
    }
    public var id: String { from.storageKey + "->" + to.storageKey }
}

/// One repository's checkout inside a workspace.
public struct WorkspaceRepo: Identifiable, Codable, Hashable {
    /// Resolved `--git-common-dir` of the source repository; stable across worktrees.
    public var id: String
    public var name: String
    /// The repository this was cut from.
    public var originPath: String
    /// `<workspace root>/<name>` — the checkout the workspace actually works in.
    public var worktreePath: String
    /// Set when `git worktree add` failed, so the board can say why.
    public var failure: String?

    public var isReady: Bool { failure == nil }

    public init(id: String, name: String, originPath: String, worktreePath: String, failure: String? = nil) {
        self.id = id
        self.name = name
        self.originPath = originPath
        self.worktreePath = worktreePath
        self.failure = failure
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = fields.value(.id, or: "")
        name = fields.value(.name, or: "repo")
        originPath = fields.value(.originPath, or: "")
        worktreePath = fields.value(.worktreePath, or: "")
        failure = fields.optional(String.self, .failure)
    }
}

/// How much an agent asks before it acts.
///
/// Only the mode a session *starts* in — ⇧⇥ still cycles it live inside the
/// session. The raw values are the ones `claude --permission-mode` accepts.
public enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    case `default`
    case plan
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .default: return "Ask every time"
        case .auto: return "Auto"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan first"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    public var detail: String {
        switch self {
        case .default: return "Asks before each action."
        case .auto: return "Decides for itself which actions need you."
        case .acceptEdits: return "Writes files without asking; still asks for commands."
        case .plan: return "Plans first, acts once you approve."
        case .dontAsk: return "Never asks — anything not pre-approved is refused."
        case .bypassPermissions: return "Acts without asking. Use with care."
        }
    }

    public var icon: String {
        switch self {
        case .default: return "hand.raised"
        case .auto: return "wand.and.stars"
        case .acceptEdits: return "square.and.pencil"
        case .plan: return "list.bullet.rectangle"
        case .dontAsk: return "nosign"
        case .bypassPermissions: return "bolt.fill"
        }
    }

    /// Worth a warning in the menu: nothing will stop the agent.
    public var isRisky: Bool { self == .bypassPermissions }
}

/// How hard a model thinks before it answers.
///
/// `claude --effort` takes one of five levels; `inherit` passes no flag at all,
/// leaving whatever the CLI is configured with. Unlike the permission mode this
/// *can* be retuned inside a running session, with `/effort <level>`.
public enum AgentEffort: String, Codable, CaseIterable, Identifiable {
    case inherit
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    /// What to pass to `--effort`, or nil to leave the flag off.
    public var flag: String? { self == .inherit ? nil : rawValue }

    public var label: String {
        switch self {
        case .inherit: return "Inherit CLI default"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        }
    }

    /// Short enough for a node header.
    public var shortLabel: String {
        switch self {
        case .inherit: return "default"
        case .xhigh: return "xhigh"
        default: return rawValue
        }
    }

    public var detail: String {
        switch self {
        case .inherit: return "Whatever the CLI is set to."
        case .low: return "Fastest, least thorough."
        case .medium: return "Balanced."
        case .high: return "Thinks longer before acting."
        case .xhigh: return "Slower still, for work that needs it."
        case .max: return "Everything it has. Slowest and dearest."
        }
    }

    public var icon: String {
        switch self {
        case .inherit: return "circle.dashed"
        case .low: return "gauge.low"
        case .medium: return "gauge.medium"
        case .high: return "gauge.high"
        case .xhigh: return "speedometer"
        case .max: return "flame"
        }
    }
}

/// A terminal placed on the canvas.
///
/// Position and size are persisted so a board keeps its shape; the running
/// process is not — terminals are re-opened on demand rather than resurrected.
public struct TerminalNode: Identifiable, Codable, Hashable {
    public enum Role: String, Codable {
        /// Runs at the workspace root, with every repository beneath it.
        case orchestrator
        /// Runs in one repository's checkout.
        case repo
        /// A plain shell, no agent.
        case shell

        public var label: String {
            switch self {
            case .orchestrator: return "Orchestrator"
            case .repo: return "Agent"
            case .shell: return "Shell"
            }
        }

        public var icon: String {
            switch self {
            case .orchestrator: return "point.3.connected.trianglepath.dotted"
            case .repo: return "hammer.fill"
            case .shell: return "terminal.fill"
            }
        }
    }

    public var id: UUID = UUID()
    public var role: Role
    public var title: String
    public var cwd: String
    /// Repository this terminal belongs to, when it is not the workspace parent.
    public var repoID: String?
    /// Session id pre-assigned to the `claude` process, so the board can match
    /// the transcript to this node instead of drawing a duplicate card.
    public var sessionID: String?
    /// Set when the orchestrator spawned this agent through the bridge, so
    /// `meshvy send` can address it.
    public var bridgeID: String?
    /// The instruction it was started with.
    public var openingTask: String?
    /// Mode this session was launched in. Decoded as nil for boards saved before
    /// the setting existed, which read as the app default.
    public var permissionMode: PermissionMode?
    /// Model it was launched with. Nil means the CLI's own default.
    public var model: String?
    /// Effort it was launched with, and what `/effort` has since set it to.
    public var effort: AgentEffort?
    public var x: Double = 0
    public var y: Double = 0
    public var width: Double = 620
    public var height: Double = 380
    public var createdAt: Date = Date()

    public var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    public var size: CGSize {
        get { CGSize(width: width, height: height) }
        set { width = newValue.width; height = newValue.height }
    }

    public init(
        id: UUID = UUID(), role: Role, title: String, cwd: String,
        repoID: String? = nil, sessionID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.cwd = cwd
        self.repoID = repoID
        self.sessionID = sessionID
    }

    /// Lenient for the same reason as `Workspace`.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = fields.value(.id, or: UUID())
        role = fields.value(.role, or: .shell)
        title = fields.value(.title, or: "Terminal")
        cwd = fields.value(.cwd, or: NSHomeDirectory())
        repoID = fields.optional(String.self, .repoID)
        sessionID = fields.optional(String.self, .sessionID)
        bridgeID = fields.optional(String.self, .bridgeID)
        openingTask = fields.optional(String.self, .openingTask)
        permissionMode = fields.optional(PermissionMode.self, .permissionMode)
        model = fields.optional(String.self, .model)
        effort = fields.optional(AgentEffort.self, .effort)
        x = fields.value(.x, or: 0)
        y = fields.value(.y, or: 0)
        width = fields.value(.width, or: 620)
        height = fields.value(.height, or: 380)
        createdAt = fields.value(.createdAt, or: Date())
    }
}

/// Role an agent plays, used for the brief Meshvy writes.
public enum AgentRole: String, Codable, CaseIterable, Identifiable {
    case orchestrator
    case worker

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .orchestrator: return "Orchestrator"
        case .worker: return "Worker"
        }
    }

    public var detail: String {
        switch self {
        case .orchestrator:
            return "Plans across every repo in the workspace and dispatches sub-agents to do the work."
        case .worker:
            return "Carries out one scoped task."
        }
    }

    public var icon: String {
        switch self {
        case .orchestrator: return "point.3.connected.trianglepath.dotted"
        case .worker: return "hammer"
        }
    }
}
