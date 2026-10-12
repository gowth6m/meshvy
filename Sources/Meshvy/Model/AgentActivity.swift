import Foundation

/// What an agent is doing right now.
///
/// Reported by the agent's own hooks rather than guessed from what it printed —
/// see `AgentHooks`. Four states, so a board of a dozen terminals can be read at
/// a glance: one of them is amber, one of them is shouting, the rest are quiet.
enum AgentState: String, Codable, Hashable {
    /// Mid-turn: thinking, or in the middle of a tool call.
    case working
    /// At the prompt with nothing asked of it.
    case waiting
    /// Stopped on something only you can answer — a permission request.
    case blocked
    /// The turn finished and it reported back.
    case done
    /// The process is gone.
    case ended

    /// The two words the node header collapses the four states into. `nil`
    /// means the state is not worth a badge.
    var badge: String? {
        switch self {
        case .working: return "RUNNING"
        case .blocked: return "NEEDS YOU"
        case .waiting, .done, .ended: return nil
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .blocked: return "Needs you"
        case .done: return "Done"
        case .ended: return "Ended"
        }
    }

    /// The turn is over and the agent is not coming back without you: either it
    /// reported, or it is stopped on a question, or the process has gone.
    var isFinished: Bool {
        switch self {
        case .done, .blocked, .ended: return true
        case .working, .waiting: return false
        }
    }

    /// Hook events arriving within the same second cannot be ordered by their
    /// timestamp, so they are ordered by how much they override each other
    /// instead. A permission question raised during a tool call is the state
    /// that matters; a turn ending always follows the last tool of that turn.
    var precedence: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .done: return 2
        case .blocked: return 3
        case .ended: return 4
        }
    }
}

/// The live state of one agent session, accumulated from its hook events.
struct AgentActivity: Codable, Hashable {
    var sessionID: String
    var state: AgentState = .waiting
    /// Tool it is in the middle of, e.g. `Edit`.
    var tool: String?
    /// One line about that tool — the file it is editing, the command it is running.
    var detail: String?
    /// Why it needs you, or the last thing it said when the turn ended.
    var message: String?
    var turns: Int = 0
    var toolCalls: Int = 0
    /// Sub-agents it has dispatched with the Agent tool.
    var subAgents: Int = 0
    var updatedAt: Date = Date()

    /// The line a node header shows under its title.
    var line: String? {
        switch state {
        case .working:
            guard let tool else { return "Thinking…" }
            return [tool, detail].compactMap { $0 }.joined(separator: "  ")
        case .blocked:
            return message ?? "Waiting for you"
        case .done:
            return message
        case .waiting, .ended:
            return nil
        }
    }
}
