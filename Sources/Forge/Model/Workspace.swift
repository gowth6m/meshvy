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
    /// `~/.forge/<slug>` — contains one subdirectory per repository.
    var root: String
    var repos: [WorkspaceRepo] = []
    /// Terminal nodes placed on this workspace's board.
    var terminals: [TerminalNode] = []
    var createdAt: Date = Date()
    var notes: String?

    var readyRepos: [WorkspaceRepo] { repos.filter(\.isReady) }
    var worktreePaths: [String] { readyRepos.map(\.worktreePath) }

    static func root(for name: String) -> String {
        Workspace.forgeHome + "/" + Workspace.slug(name)
    }

    /// Everything Forge creates lives here, out of the way of your own folders.
    static var forgeHome: String { NSHomeDirectory() + "/.forge" }

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
}

/// Role an agent plays, used for the brief Forge writes.
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
