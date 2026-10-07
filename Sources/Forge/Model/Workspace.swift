import Foundation

/// A set of repositories worked on together.
///
/// The board shows one workspace at a time. Everything else — worktrees,
/// sessions, agents — hangs off the repos listed here.
struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var repos: [WorkspaceRepo] = []
    var linkedWorktrees: [LinkedWorktree] = []
    /// Where `git worktree add` puts new checkouts. Each link gets a folder
    /// under here with one subfolder per repo.
    var worktreeRoot: String
    var createdAt: Date = Date()

    static func defaultWorktreeRoot(for name: String) -> String {
        NSHomeDirectory() + "/Forge/" + Workspace.slug(name)
    }

    /// Filesystem-safe form of a display name.
    static func slug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workspace" : collapsed
    }

    func link(named branch: String) -> LinkedWorktree? {
        linkedWorktrees.first { $0.branch == branch }
    }

    /// Every checkout path this workspace knows about, for scoping the board.
    var allRepoPaths: [String] { repos.map(\.path) }
}

/// One repository inside a workspace, identified by its shared git directory so
/// it stays the same object no matter which worktree you came in through.
struct WorkspaceRepo: Identifiable, Codable, Hashable {
    /// Resolved `--git-common-dir`.
    var id: String
    /// Main working tree.
    var path: String
    var name: String
    /// Branch new linkedWorktrees are cut from when nothing else is specified.
    var defaultBranch: String?
}

/// A branch created across every repo in the workspace at once, with one
/// worktree per repo. This is the unit of parallel work: one task, one branch
/// name, N checkouts that move together.
struct LinkedWorktree: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Display name. Usually the same as the branch.
    var name: String
    var branch: String
    var baseRef: String?
    var createdAt: Date = Date()
    var checkouts: [LinkedCheckout] = []
    /// Free-form note — what this link is for.
    var intent: String?

    func checkout(repoID: String) -> LinkedCheckout? {
        checkouts.first { $0.repoID == repoID }
    }

    var paths: [String] { checkouts.map(\.path) }
}

/// One repo's checkout within a link.
struct LinkedCheckout: Codable, Hashable, Identifiable {
    var repoID: String
    var repoName: String
    var path: String
    /// Set when the worktree could not be created, so the UI can say why.
    var failure: String?

    var id: String { repoID }
    var isReady: Bool { failure == nil }
}

/// What a launched session is there to do. Only affects the preamble Forge puts
/// in front of the prompt and how the card is labelled.
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
            return "Plans the work across every repo in the link and dispatches teammates to do it."
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

/// What an agent is pointed at.
enum AgentScope: Hashable {
    /// Every repository in the workspace and every linked worktree in it.
    case workspace
    /// One linked worktree — the same branch across every repo.
    case link(UUID)
    /// A single checkout.
    case checkout(String)

    var label: String {
        switch self {
        case .workspace: return "Whole workspace"
        case .link: return "This linked worktree"
        case .checkout: return "This checkout"
        }
    }

    var icon: String {
        switch self {
        case .workspace: return "rectangle.3.group"
        case .link: return "link"
        case .checkout: return "square.on.square"
        }
    }
}

/// Everything needed to start a `claude` process.
struct AgentLaunch {
    var scope: AgentScope = .workspace
    var role: AgentRole = .orchestrator
    var name: String = ""
    var prompt: String = ""
    /// Working directory — the link checkout the agent starts in.
    var cwd: String = ""
    /// Sibling repos granted tool access via `--add-dir`.
    var additionalDirs: [String] = []
    var model: String? = ModelDefaults.modelID
    var permissionMode: String = "acceptEdits"
    /// Run headless in the background rather than opening a Terminal window.
    var runsInBackground: Bool = true
    /// Context Forge prepends to the prompt describing what the agent owns.
    var brief: String?

    static let permissionModes = ["default", "acceptEdits", "plan", "bypassPermissions"]
}
