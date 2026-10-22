import Foundation

/// Where one thread stands, in the words the sidebar and its card use.
///
/// A workspace works the way a project does in Claude Code: one main chat — the
/// coordinator — takes your requests, and each piece of work goes to a thread
/// with its own agent. A thread's state is what you scan the list for, so it is
/// a handful of plain answers to "do I need to look at this?" rather than the
/// agent's raw lifecycle. It is derived, never stored: the agent's own hooks
/// say what it is doing, and the only thing a thread remembers is whether it
/// has been resolved.
public enum ThreadState: String, Codable, Hashable, CaseIterable {
    /// Stopped on something only you can answer.
    case needsYou
    /// Mid-turn.
    case working
    /// Finished a turn and reported back. Worth a read.
    case ready
    /// At its prompt with nothing new to say.
    case idle
    /// Its process is gone; restart it to pick the work back up.
    case stopped
    /// Done and put away.
    case resolved

    /// Resolves a thread's state from what is known about it.
    ///
    /// Resolution wins over everything — you put it away, so it stays away
    /// until you, or the coordinator, write to it again. After that the process
    /// itself: a thread that is not running is stopped whatever it last said.
    public static func of(
        activity: AgentActivity?,
        isRunning: Bool,
        isResolved: Bool
    ) -> ThreadState {
        if isResolved { return .resolved }
        guard isRunning else { return .stopped }
        switch activity?.state {
        case .blocked: return .needsYou
        case .working: return .working
        case .done: return .ready
        case .ended: return .stopped
        case .waiting, nil: return .idle
        }
    }

    public var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .ready: return "Ready"
        case .idle: return "Idle"
        case .stopped: return "Stopped"
        case .resolved: return "Resolved"
        }
    }

    public var icon: String {
        switch self {
        case .needsYou: return "hand.raised.fill"
        case .working: return "circle.dotted"
        case .ready: return "checkmark.circle.fill"
        case .idle: return "pause.circle"
        case .stopped: return "stop.circle"
        case .resolved: return "checkmark.seal"
        }
    }

    /// Order in the thread list: whatever wants you first.
    public var rank: Int {
        switch self {
        case .needsYou: return 0
        case .ready: return 1
        case .working: return 2
        case .idle: return 3
        case .stopped: return 4
        case .resolved: return 5
        }
    }

    /// Whether the thread is still part of the work in hand.
    public var isOpen: Bool { self != .resolved }
}
