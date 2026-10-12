import CoreGraphics
import Foundation

/// A workspace is a set of worktrees — one per repository — all cut from the
/// same base on the same branch, living side by side under one folder.
///
/// That folder is the parent the orchestrator works from: the repositories are
/// literally its subdirectories, so an agent started there can see and change
/// all of them without any extra plumbing.
struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Branch checked out in every repository of this workspace.
    var branch: String
    /// What the branch was cut from. Nil means each repo's own default branch.
    var baseRef: String?
    /// `~/.meshvy/<slug>` — contains one subdirectory per repository.
    var root: String
    var repos: [WorkspaceRepo] = []
    /// The Claude Code session that sits on top of the whole workspace. It is
    /// hosted by the workspace node itself rather than floating separately.
    var orchestrator: TerminalNode?
    /// Per-repo agents and plain shells, placed freely on the board.
    var terminals: [TerminalNode] = []
    /// Browser nodes on the board — a page you can watch and an agent can drive.
    var browsers: [BrowserNode] = []
    /// Size of the workspace node on the board.
    var boardWidth: Double = 780
    var boardHeight: Double = 520
    var createdAt: Date = Date()
    var notes: String?
    /// Set when the workspace has been archived: the worktrees stay exactly
    /// where they are, it just leaves the board and the switcher. Decoded as
    /// nil for boards saved before archiving existed, which read as active.
    var archivedAt: Date?

    var readyRepos: [WorkspaceRepo] { repos.filter(\.isReady) }
    var isArchived: Bool { archivedAt != nil }
    /// Every terminal on the board, orchestrator included.
    var allTerminals: [TerminalNode] { (orchestrator.map { [$0] } ?? []) + terminals }
    /// Height the node collapses to when no orchestrator is running.
    static let idleHeight: Double = 186
    var worktreePaths: [String] { readyRepos.map(\.worktreePath) }

    static func root(for name: String) -> String {
        Workspace.meshvyHome + "/" + Workspace.slug(name)
    }

    /// Everything Meshvy creates lives here, out of the way of your own folders.
    static var meshvyHome: String { NSHomeDirectory() + "/.meshvy" }

    /// Filesystem- and branch-safe form of a display name.
    static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed
    }

    init(
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
    init(from decoder: Decoder) throws {
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
        createdAt = fields.value(.createdAt, or: Date())
        notes = fields.optional(String.self, .notes)
        archivedAt = fields.optional(Date.self, .archivedAt)
    }
}

/// One repository's checkout inside a workspace.
struct WorkspaceRepo: Identifiable, Codable, Hashable {
    /// Resolved `--git-common-dir` of the source repository; stable across worktrees.
    var id: String
    var name: String
    /// The repository this was cut from.
    var originPath: String
    /// `<workspace root>/<name>` — the checkout the workspace actually works in.
    var worktreePath: String
    /// Set when `git worktree add` failed, so the board can say why.
    var failure: String?

    var isReady: Bool { failure == nil }

    init(id: String, name: String, originPath: String, worktreePath: String, failure: String? = nil) {
        self.id = id
        self.name = name
        self.originPath = originPath
        self.worktreePath = worktreePath
        self.failure = failure
    }

    init(from decoder: Decoder) throws {
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
enum PermissionMode: String, Codable, CaseIterable, Identifiable {
    case `default`
    case plan
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return "Ask every time"
        case .auto: return "Auto"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan first"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass permissions"
        }
    }

    var detail: String {
        switch self {
        case .default: return "Asks before each action."
        case .auto: return "Decides for itself which actions need you."
        case .acceptEdits: return "Writes files without asking; still asks for commands."
        case .plan: return "Plans first, acts once you approve."
        case .dontAsk: return "Never asks — anything not pre-approved is refused."
        case .bypassPermissions: return "Acts without asking. Use with care."
        }
    }

    var icon: String {
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
    var isRisky: Bool { self == .bypassPermissions }
}

/// How hard a model thinks before it answers.
///
/// `claude --effort` takes one of five levels; `inherit` passes no flag at all,
/// leaving whatever the CLI is configured with. Unlike the permission mode this
/// *can* be retuned inside a running session, with `/effort <level>`.
enum AgentEffort: String, Codable, CaseIterable, Identifiable {
    case inherit
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    /// What to pass to `--effort`, or nil to leave the flag off.
    var flag: String? { self == .inherit ? nil : rawValue }

    var label: String {
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
    var shortLabel: String {
        switch self {
        case .inherit: return "default"
        case .xhigh: return "xhigh"
        default: return rawValue
        }
    }

    var detail: String {
        switch self {
        case .inherit: return "Whatever the CLI is set to."
        case .low: return "Fastest, least thorough."
        case .medium: return "Balanced."
        case .high: return "Thinks longer before acting."
        case .xhigh: return "Slower still, for work that needs it."
        case .max: return "Everything it has. Slowest and dearest."
        }
    }

    var icon: String {
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
struct TerminalNode: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        /// Runs at the workspace root, with every repository beneath it.
        case orchestrator
        /// Runs in one repository's checkout.
        case repo
        /// A plain shell, no agent.
        case shell

        var label: String {
            switch self {
            case .orchestrator: return "Orchestrator"
            case .repo: return "Agent"
            case .shell: return "Shell"
            }
        }

        var icon: String {
            switch self {
            case .orchestrator: return "point.3.connected.trianglepath.dotted"
            case .repo: return "hammer.fill"
            case .shell: return "terminal.fill"
            }
        }
    }

    var id: UUID = UUID()
    var role: Role
    var title: String
    var cwd: String
    /// Repository this terminal belongs to, when it is not the workspace parent.
    var repoID: String?
    /// Session id pre-assigned to the `claude` process, so the board can match
    /// the transcript to this node instead of drawing a duplicate card.
    var sessionID: String?
    /// Set when the orchestrator spawned this agent through the bridge, so
    /// `meshvy send` can address it.
    var bridgeID: String?
    /// The instruction it was started with.
    var openingTask: String?
    /// Mode this session was launched in. Decoded as nil for boards saved before
    /// the setting existed, which read as the app default.
    var permissionMode: PermissionMode?
    /// Model it was launched with. Nil means the CLI's own default.
    var model: String?
    /// Effort it was launched with, and what `/effort` has since set it to.
    var effort: AgentEffort?
    var x: Double = 0
    var y: Double = 0
    var width: Double = 620
    var height: Double = 380
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
    init(from decoder: Decoder) throws {
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
enum AgentRole: String, Codable, CaseIterable, Identifiable {
    case orchestrator
    case worker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .orchestrator: return "Orchestrator"
        case .worker: return "Worker"
        }
    }

    var detail: String {
        switch self {
        case .orchestrator:
            return "Plans across every repo in the workspace and dispatches sub-agents to do the work."
        case .worker:
            return "Carries out one scoped task."
        }
    }

    var icon: String {
        switch self {
        case .orchestrator: return "point.3.connected.trianglepath.dotted"
        case .worker: return "hammer"
        }
    }
}
