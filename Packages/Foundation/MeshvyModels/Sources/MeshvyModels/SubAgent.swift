import Foundation

/// A sub-agent the orchestrator dispatched with the Agent tool.
///
/// These never appear in `~/.claude/sessions` — the Agent tool runs them inside
/// the parent session, so the only record is a `tool_use` block in the parent's
/// transcript and, once it finishes, the matching `tool_result`.
public struct SubAgent: Identifiable, Hashable {
    public enum State: Hashable {
        case running
        case finished(ok: Bool)

        public var isRunning: Bool { if case .running = self { return true } else { return false } }
    }

    /// The tool-use id, stable for the life of the call.
    public var id: String
    /// Short label the orchestrator gave the task.
    public var title: String
    /// Which agent definition was used, e.g. `general-purpose`.
    public var kind: String
    /// The full instruction it was handed.
    public var prompt: String
    public var state: State = .running
    public var startedAt: Date?
    public var finishedAt: Date?
    /// First lines of what it reported back.
    public var result: String?
    public var totalTokens: Int?
    /// Handle the parent can use to continue it.
    public var agentID: String?

    public init(
        id: String,
        title: String,
        kind: String,
        prompt: String,
        state: State = .running,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        result: String? = nil,
        totalTokens: Int? = nil,
        agentID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.prompt = prompt
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.totalTokens = totalTokens
        self.agentID = agentID
    }

    public var subtitle: String {
        switch state {
        case .running: return kind
        case .finished(let ok): return ok ? kind : kind + " · failed"
        }
    }
}
