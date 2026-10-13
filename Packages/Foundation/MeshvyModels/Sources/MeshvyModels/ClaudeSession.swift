import Foundation

/// Lifecycle of a session as far as we can tell from disk + process table.
public enum SessionStatus: String, Codable, Hashable {
    /// Process alive and the CLI reports it is working.
    case busy
    /// Process alive and waiting on input.
    case idle
    /// Transcript on disk, no live process.
    case ended

    public var label: String {
        switch self {
        case .busy: return "Working"
        case .idle: return "Waiting"
        case .ended: return "Ended"
        }
    }

    public var isLive: Bool { self != .ended }
}

/// A live `claude` process, read from `~/.claude/sessions/<pid>.json`.
public struct LiveSession: Identifiable, Hashable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    public var name: String?
    public var version: String?
    public var entrypoint: String?
    public var kind: String?
    public var status: SessionStatus
    public var startedAt: Date?
    public var updatedAt: Date?

    public init(
        pid: Int32,
        sessionId: String,
        cwd: String? = nil,
        name: String? = nil,
        version: String? = nil,
        entrypoint: String? = nil,
        kind: String? = nil,
        status: SessionStatus,
        startedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var id: Int32 { pid }
}

/// Cheap metadata for one transcript file. Built without parsing the whole
/// file — see `SessionIndexer` for what is and is not read.
public struct SessionSummary: Identifiable, Hashable {
    public var id: String
    public var fileURL: URL
    public var projectDirName: String

    public var cwd: String?
    public var gitBranch: String?
    public var cliVersion: String?
    public var model: String?

    /// `ai-title` record when the CLI has named the session.
    public var aiTitle: String?
    /// First human turn, with system scaffolding stripped.
    public var firstPrompt: String?

    public var startedAt: Date?
    public var lastActivityAt: Date
    public var fileSize: Int64

    public var userTurns: Int = 0
    public var assistantTurns: Int = 0
    public var toolCalls: Int = 0
    /// Context occupied at the last assistant turn (input + cache), not a cumulative total.
    public var contextTokens: Int = 0
    public var isSidechain: Bool = false

    /// True once the background pass has filled in the parsed fields.
    public var isIndexed: Bool = false

    public init(
        id: String,
        fileURL: URL,
        projectDirName: String,
        cwd: String? = nil,
        gitBranch: String? = nil,
        cliVersion: String? = nil,
        model: String? = nil,
        aiTitle: String? = nil,
        firstPrompt: String? = nil,
        startedAt: Date? = nil,
        lastActivityAt: Date,
        fileSize: Int64,
        userTurns: Int = 0,
        assistantTurns: Int = 0,
        toolCalls: Int = 0,
        contextTokens: Int = 0,
        isSidechain: Bool = false,
        isIndexed: Bool = false
    ) {
        self.id = id
        self.fileURL = fileURL
        self.projectDirName = projectDirName
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.cliVersion = cliVersion
        self.model = model
        self.aiTitle = aiTitle
        self.firstPrompt = firstPrompt
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.fileSize = fileSize
        self.userTurns = userTurns
        self.assistantTurns = assistantTurns
        self.toolCalls = toolCalls
        self.contextTokens = contextTokens
        self.isSidechain = isSidechain
        self.isIndexed = isIndexed
    }

    /// Best available human-facing name, never empty.
    public var displayTitle: String {
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let firstPrompt, !firstPrompt.isEmpty { return firstPrompt }
        return "Session \(id.prefix(8))"
    }

    /// Working directory, falling back to decoding the project folder name.
    public var resolvedPath: String {
        cwd ?? SessionSummary.decodeProjectDir(projectDirName)
    }

    public var workspaceName: String {
        URL(fileURLWithPath: resolvedPath).lastPathComponent
    }

    /// `~/.claude/projects` folder names are the cwd with separators flattened to
    /// `-`, which is lossy (a literal `-` in a path is indistinguishable). Used
    /// only as a fallback when no record carried a `cwd`.
    public static func decodeProjectDir(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        return "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
    }
}

/// One rendered row in the transcript reader.
public struct TranscriptEvent: Identifiable, Hashable {
    public enum Kind: Hashable {
        case userMessage
        case assistantMessage
        case thinking
        case toolUse(name: String)
        case toolResult(ok: Bool)
        case system
        case attachment(kind: String)

        public var label: String {
            switch self {
            case .userMessage: return "You"
            case .assistantMessage: return "Claude"
            case .thinking: return "Thinking"
            case .toolUse(let name): return name
            case .toolResult(let ok): return ok ? "Result" : "Error"
            case .system: return "System"
            case .attachment(let kind): return kind.isEmpty ? "Attachment" : kind
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var timestamp: Date?
    public var text: String
    public var model: String?
    public var isSidechain: Bool
    /// Collapsed by default when the body is long or machine-facing.
    public var startsCollapsed: Bool

    /// One-line summary shown while collapsed. Built once at load rather than
    /// sliced out of `text` on every render.
    public var preview: String = ""

    public init(
        id: String,
        kind: Kind,
        timestamp: Date? = nil,
        text: String,
        model: String? = nil,
        isSidechain: Bool,
        startsCollapsed: Bool,
        preview: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.text = text
        self.model = model
        self.isSidechain = isSidechain
        self.startsCollapsed = startsCollapsed
        self.preview = preview
    }

    public static func makePreview(_ text: String) -> String {
        String(text.prefix(140))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Full transcript plus totals that are only knowable from a complete parse.
public struct Transcript {
    public var sessionId: String
    public var events: [TranscriptEvent]
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var cacheReadTokens: Int
    public var toolUseCounts: [String: Int]
    /// True when only the tail of the transcript was decoded, so the counts and
    /// token totals describe the shown window rather than the whole session.
    public var truncated: Bool

    /// Counts for the reader's filter bar. Computed once here rather than in the
    /// view body — a long session has thousands of events, and recounting them
    /// on every render is what made opening the panel feel slow.
    public var toolEventCount = 0
    public var thinkingEventCount = 0
    public var systemEventCount = 0

    public init(
        sessionId: String,
        events: [TranscriptEvent],
        totalInputTokens: Int,
        totalOutputTokens: Int,
        cacheReadTokens: Int,
        toolUseCounts: [String: Int],
        truncated: Bool,
        toolEventCount: Int = 0,
        thinkingEventCount: Int = 0,
        systemEventCount: Int = 0
    ) {
        self.sessionId = sessionId
        self.events = events
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.toolUseCounts = toolUseCounts
        self.truncated = truncated
        self.toolEventCount = toolEventCount
        self.thinkingEventCount = thinkingEventCount
        self.systemEventCount = systemEventCount
    }

    public mutating func tallyEventKinds() {
        var tools = 0
        var thinking = 0
        var system = 0
        for event in events {
            switch event.kind {
            case .toolUse, .toolResult: tools += 1
            case .thinking: thinking += 1
            case .system, .attachment: system += 1
            default: break
            }
        }
        toolEventCount = tools
        thinkingEventCount = thinking
        systemEventCount = system
    }
}
