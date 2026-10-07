import Foundation

/// Lifecycle of a session as far as we can tell from disk + process table.
enum SessionStatus: String, Codable, Hashable {
    /// Process alive and the CLI reports it is working.
    case busy
    /// Process alive and waiting on input.
    case idle
    /// Transcript on disk, no live process.
    case ended

    var label: String {
        switch self {
        case .busy: return "Working"
        case .idle: return "Waiting"
        case .ended: return "Ended"
        }
    }

    var isLive: Bool { self != .ended }
}

/// A live `claude` process, read from `~/.claude/sessions/<pid>.json`.
struct LiveSession: Identifiable, Hashable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var name: String?
    var version: String?
    var entrypoint: String?
    var kind: String?
    var status: SessionStatus
    var startedAt: Date?
    var updatedAt: Date?

    var id: Int32 { pid }
}

/// Cheap metadata for one transcript file. Built without parsing the whole
/// file — see `SessionIndexer` for what is and is not read.
struct SessionSummary: Identifiable, Hashable {
    var id: String
    var fileURL: URL
    var projectDirName: String

    var cwd: String?
    var gitBranch: String?
    var cliVersion: String?
    var model: String?

    /// `ai-title` record when the CLI has named the session.
    var aiTitle: String?
    /// First human turn, with system scaffolding stripped.
    var firstPrompt: String?

    var startedAt: Date?
    var lastActivityAt: Date
    var fileSize: Int64

    var userTurns: Int = 0
    var assistantTurns: Int = 0
    var toolCalls: Int = 0
    /// Context occupied at the last assistant turn (input + cache), not a cumulative total.
    var contextTokens: Int = 0
    var isSidechain: Bool = false

    /// True once the background pass has filled in the parsed fields.
    var isIndexed: Bool = false

    /// Best available human-facing name, never empty.
    var displayTitle: String {
        if let aiTitle, !aiTitle.isEmpty { return aiTitle }
        if let firstPrompt, !firstPrompt.isEmpty { return firstPrompt }
        return "Session \(id.prefix(8))"
    }

    /// Working directory, falling back to decoding the project folder name.
    var resolvedPath: String {
        cwd ?? SessionSummary.decodeProjectDir(projectDirName)
    }

    var workspaceName: String {
        URL(fileURLWithPath: resolvedPath).lastPathComponent
    }

    /// `~/.claude/projects` folder names are the cwd with separators flattened to
    /// `-`, which is lossy (a literal `-` in a path is indistinguishable). Used
    /// only as a fallback when no record carried a `cwd`.
    static func decodeProjectDir(_ name: String) -> String {
        guard name.hasPrefix("-") else { return name }
        return "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
    }
}

/// One rendered row in the transcript reader.
struct TranscriptEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case userMessage
        case assistantMessage
        case thinking
        case toolUse(name: String)
        case toolResult(ok: Bool)
        case system
        case attachment(kind: String)

        var label: String {
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

    var id: String
    var kind: Kind
    var timestamp: Date?
    var text: String
    var model: String?
    var isSidechain: Bool
    /// Collapsed by default when the body is long or machine-facing.
    var startsCollapsed: Bool
}

/// Full transcript plus totals that are only knowable from a complete parse.
struct Transcript {
    var sessionId: String
    var events: [TranscriptEvent]
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var cacheReadTokens: Int
    var toolUseCounts: [String: Int]
    var truncated: Bool
}
