import Foundation

/// What a drag on the board will do.
///
/// The board used to answer this with modifiers nobody could see: a plain drag
/// panned, and a drag with ⌘ held drew a rectangle that started a Claude Code
/// agent — which is a lot to hide behind a key. A visible tool says what will
/// happen before it happens, and it is the one idea every canvas app on the
/// machine already shares.
public enum BoardTool: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Select, move, resize, link. Where the board lives; everything else is
    /// something you step into and come back from.
    case select
    /// Pan, for people who would rather drag the board than the scroll wheel.
    case hand
    /// Draw a new Claude Code agent.
    case agent
    /// Draw a new plain shell.
    case shell
    /// Draw a new browser.
    case browser

    public var id: String { rawValue }

    /// Tools that make something when you drag. They take over the board
    /// completely while active — a node under the pointer is canvas to draw on,
    /// not a terminal to click into — and hand it back as soon as they are done.
    public var isCreation: Bool {
        switch self {
        case .select, .hand: return false
        case .agent, .shell, .browser: return true
        }
    }

    public var label: String {
        switch self {
        case .select: return "Select"
        case .hand: return "Hand"
        case .agent: return "Agent"
        case .shell: return "Shell"
        case .browser: return "Browser"
        }
    }

    /// Single keys, as every canvas app has them. Shown on the tool's tooltip,
    /// so the palette teaches them rather than hiding them in a sheet.
    public var key: Character {
        switch self {
        case .select: return "v"
        case .hand: return "h"
        case .agent: return "a"
        case .shell: return "s"
        case .browser: return "b"
        }
    }

    /// The same glyphs the nodes themselves use, so the palette and the board
    /// agree about what each thing looks like.
    public var icon: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .agent: return "hammer.fill"
        case .shell: return "terminal.fill"
        case .browser: return "globe"
        }
    }

    public var hint: String {
        switch self {
        case .select: return "Select, move, resize and link"
        case .hand: return "Drag the board — or hold space with any tool"
        case .agent: return "Drag out a Claude Code agent"
        case .shell: return "Drag out a plain shell"
        case .browser: return "Drag out a browser"
        }
    }

    /// Size a click rather than a drag makes, when the tool is a creation one.
    public var defaultSize: CGSize {
        switch self {
        case .browser: return CGSize(width: 620, height: 440)
        default: return CGSize(width: 620, height: 380)
        }
    }

    /// Smallest rectangle worth treating as deliberate. A flick of the wrist is
    /// not a request for a process, and starting one takes a real drag — or a
    /// plain click, which is unambiguous.
    public static let minimumDrawn = CGSize(width: 140, height: 100)
}
