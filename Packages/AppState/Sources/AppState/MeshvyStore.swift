import AgentKit
import AppKit
import BrowserKit
import FileSystemKit
import GitKit
import MeshvyCore
import MeshvyModels
import Observation
import PersistenceKit
import SessionKit
import SwiftUI
import TerminalKit
import UpdateKit
import WorkspaceKit

/// Everything the board renders from, plus the refresh machinery.
///
/// A workspace is a set of worktrees — one per repository, all on the same
/// branch, under `~/.meshvy/<slug>/`. That folder is the parent an orchestrator
/// works from. A fresh install has no workspaces, so the board starts empty.
@MainActor
@Observable
public final class MeshvyStore {
    public init() {}

    /// One store per process. The SwiftUI scene and the headless harnesses both
    /// reach for this — two instances would mean two sets of timers, two
    /// filesystem watchers, and two readers racing for the same agent-bridge
    /// request files.
    public static let shared = MeshvyStore()

    // MARK: Workspaces
    public internal(set) var workspaces: [Workspace] = []
    public internal(set) var activeWorkspaceID: UUID?

    public var activeWorkspace: Workspace? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == activeWorkspaceID }
    }

    public var hasWorkspace: Bool { activeWorkspace != nil }

    /// Workspaces on the board and in the switcher.
    public var liveWorkspaces: [Workspace] { workspaces.filter { !$0.isArchived } }
    /// Put away, newest first. Their worktrees are untouched on disk.
    public var archivedWorkspaces: [Workspace] {
        workspaces.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    // MARK: Data
    public internal(set) var allSessions: [SessionSummary] = []
    /// Live git state for the active workspace's checkouts, keyed by path.
    public internal(set) var worktrees: [String: Worktree] = [:]
    public internal(set) var live: [String: LiveSession] = [:]
    /// Sub-agents the orchestrator has dispatched, read from its transcript.
    public internal(set) var subAgents: [SubAgent] = []
    /// What each agent is doing, keyed by session id. Fed by the agent's own
    /// hooks — see `AgentHooks`.
    public internal(set) var activity: [String: AgentActivity] = [:]
    /// Terminals that changed state while you were looking elsewhere.
    public internal(set) var unread: Set<UUID> = []
    /// Changed files per checkout, keyed by worktree path.
    public internal(set) var changes: [String: [FileChange]] = [:]
    /// The file currently open in the diff viewer.
    public internal(set) var openFile: (repoPath: String, change: FileChange)?
    public internal(set) var openDiff: FileDiff?
    public internal(set) var isLoadingDiff = false
    public internal(set) var graph = CanvasGraph()

    // MARK: View state
    public var viewport = Viewport()
    public var selection: NodeID?
    public var searchQuery = "" { didSet { recomputeMatches() } }
    public internal(set) var matchingNodes: Set<String> = []

    public var showEndedSessions = true { didSet { rebuild(); persistLayout() } }
    public var invertScroll = false { didSet { persistLayout() } }
    public var inspectorVisible = true
    public var sidebarVisible = true
    public var sidebarWidth: Double = 262
    public var inspectorWidth: Double = 430

    /// Open state of the ⌘K palette.
    public var paletteOpen = false
    public var shortcutsOpen = false

    /// Something is drawn over the board and owns the wheel while it is up.
    /// The canvas reads this to stand its scroll monitor down: both of these
    /// open on a keystroke, and a pointer that has not moved since is still
    /// recorded as being over the canvas.
    public var isOverlayOpen: Bool { paletteOpen || shortcutsOpen }

    /// Permission mode new agents start in. Only the starting mode — ⇧⇥ still
    /// cycles it live inside the session, exactly as it does in Claude Code.
    public var permissionMode = PermissionMode.acceptEdits { didSet { persistLayout() } }
    /// Effort new agents start with. Unlike the permission mode this one *can*
    /// be retuned in a running session, with `/effort`.
    public var agentEffort = AgentEffort.inherit { didSet { persistLayout() } }

    /// Terminal the pointer is over, and the one it has dwelled on long enough
    /// to be handed the scroll wheel. Nil means the canvas keeps panning.
    public internal(set) var hoveredTerminal: UUID?
    public internal(set) var armedTerminal: UUID?
    var armTask: Task<Void, Never>?

    /// How long the pointer has to rest on a terminal before it takes the
    /// wheel. Long enough that flicking across the board never scrolls one by
    /// accident, short enough not to feel like waiting.
    static let armDelay = Duration.milliseconds(500)

    public internal(set) var isIndexing = false
    public internal(set) var isLoadingGit = false
    public internal(set) var isWorking = false
    public internal(set) var statusLine = "No workspace"
    public internal(set) var banner: Banner?

    public struct Banner: Identifiable {
        public enum Kind { case info, success, failure }
        public var id = UUID()
        public var kind: Kind
        public var title: String
        public var detail: String?

        public init(
            id: UUID = UUID(),
            kind: Kind,
            title: String,
            detail: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
        }
    }

    // MARK: Transcript reader
    public internal(set) var transcript: Transcript?
    public internal(set) var transcriptSessionID: String?
    public internal(set) var isLoadingTranscript = false

    // MARK: Collaborators
    public let terminals = TerminalRegistry()
    public let browsers = BrowserRegistry()
    public let models = ModelCatalog()
    public let updates = UpdateService()
    public let notifier = Notifier()
    let indexer = SessionIndexer()
    let liveMonitor = LiveSessionMonitor()
    let git = GitService()
    let builder = WorkspaceBuilder()
    let composer = BoardComposer()
    let subAgentTracker = SubAgentTracker()
    let workspaceStore = WorkspaceStore()
    let layoutStore = FileStore<SavedLayout>(filename: "layout.json")
    let transcriptLoader = TranscriptLoader()

    var saved = SavedLayout()
    var pinned: [String: CGPoint] = [:]
    var watchers: [DirectoryWatcher] = []
    var bridgeWatcher: DirectoryWatcher?
    var hookWatcher: DirectoryWatcher?
    var browserWatcher: DirectoryWatcher?
    var liveTimer: Timer?
    var gitTimer: Timer?
    var hasFitInitially = false
    var sessionIndexByID: [String: Int] = [:]
    var hasBootstrapped = false
}
