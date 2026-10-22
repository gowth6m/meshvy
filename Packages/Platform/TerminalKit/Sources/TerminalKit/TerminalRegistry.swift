import AppKit
import DesignSystem
import MeshvyModels
import Observation
import SwiftTerm

/// One running terminal, owned by the registry rather than by a SwiftUI view.
///
/// SwiftUI rebuilds node views constantly as the canvas pans and zooms; if the
/// `LocalProcessTerminalView` were created in `makeNSView` the shell would be
/// killed and restarted every time. The view is made once here and handed back
/// on each render, so the process lives as long as the node does.
@MainActor
public final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    public let id: UUID
    public let view: LocalProcessTerminalView
    /// Type-erased handle for view code, which must not import SwiftTerm (its
    /// `Color` would shadow SwiftUI's).
    public var surface: NSView { view }
    public private(set) var isRunning = true
    public private(set) var exitCode: Int32?
    /// Set when the terminal is running a `claude` session we pre-assigned an id to.
    public let sessionID: String?

    public var onExit: ((Int32?) -> Void)?

    public init(id: UUID, sessionID: String?, cwd: String, command: [String], environment: [String: String]) {
        self.id = id
        self.sessionID = sessionID
        view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 380))
        super.init()

        view.processDelegate = self
        Self.style(view)

        // Run under a login shell so PATH, version managers and the user's
        // profile behave exactly as they would in Terminal.app.
        //
        // A plain shell has no command, and `-c` with nothing left to run is a
        // shell that exits the moment it has cleared the screen — every New
        // shell came up already marked "exited". It is replaced with an
        // interactive login shell instead, in the same folder.
        let run = command.isEmpty
            ? "exec " + Self.quote(Self.loginShell) + " -l"
            : command.map(Self.quote).joined(separator: " ")
        let script = "cd \(Self.quote(cwd)) || exit 1; clear; " + run
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        for (key, value) in environment { env.append("\(key)=\(value)") }

        view.startProcess(
            executable: Self.loginShell,
            args: ["-l", "-c", script],
            environment: env,
            execName: nil
        )
    }

    /// Grid dimensions, for diagnostics.
    public var grid: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Visible screen contents, for diagnostics.
    public var screenText: String {
        let terminal = view.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols - 1, row: rows - 1)
        )
    }

    /// Sends text as if typed. Used to give a coordinator a follow-up task.
    public func send(_ text: String) {
        view.send(txt: text)
    }

    public func terminate() {
        guard isRunning else { return }
        // SIGHUP mirrors closing a terminal window: the shell tears down its
        // children rather than leaving orphaned agents behind.
        kill(view.process.shellPid, SIGHUP)
    }

    public nonisolated func processTerminated(source: TerminalView, exitCode code: Int32?) {
        // SwiftTerm hands over the raw `waitpid` status, not the exit code: a
        // shell that could not find its command reports 32512, which is 127 a
        // byte up. Decoded here, so nothing downstream has to know.
        let decoded = code.map(Self.exitStatus)
        Task { @MainActor in
            isRunning = false
            exitCode = decoded
            onExit?(decoded)
        }
    }

    /// What a shell would print as `$?` for a wait status: the exit code, or
    /// 128 plus the signal for a process that was killed.
    public nonisolated static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    public nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    public nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    public nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Match the canvas palette so a terminal reads as part of the board — down
    /// to the ANSI colours, so what the agent prints is Night Owl too.
    private static func style(_ view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = NSColor(hex: Theme.Hex.canvasDeep)
        view.nativeForegroundColor = NSColor(hex: Theme.Hex.textPrimary)
        view.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.caretColor = NSColor(hex: Theme.Hex.accent)
        view.selectedTextBackgroundColor = NSColor(hex: Theme.NightOwl.surface)
        view.selectedTextForegroundColor = NSColor(hex: Theme.Hex.textPrimary)
        view.installColors(ansiPalette)
    }

    /// The sixteen ANSI slots, in SwiftTerm's order: the eight base colours then
    /// their bright variants, each lifted towards the foreground so bold output
    /// stays distinguishable without leaving the palette.
    private static let ansiPalette: [SwiftTerm.Color] = {
        let base: [UInt32] = [
            Theme.NightOwl.background,  // black
            Theme.NightOwl.red,
            Theme.NightOwl.green,
            Theme.NightOwl.yellow,
            Theme.NightOwl.blue,
            Theme.NightOwl.purple,      // magenta
            Theme.NightOwl.teal,        // cyan
            Theme.NightOwl.foreground   // white
        ]
        let bright: [UInt32] = [
            Theme.NightOwl.muted        // bright black
        ] + base[1...6].map { Theme.blend($0, Theme.NightOwl.foreground, 0.22) }
            + [Theme.blend(Theme.NightOwl.foreground, 0xFFFFFF, 0.5)]

        return (base + bright).map(terminalColor)
    }()

    private static func terminalColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red8: UInt16((hex >> 16) & 0xFF),
            green8: UInt16((hex >> 8) & 0xFF),
            blue8: UInt16(hex & 0xFF)
        )
    }
}

/// Holds every live terminal, keyed by its node id.
@MainActor
@Observable
public final class TerminalRegistry {
    public init() {}

    private var sessions: [UUID: TerminalSession] = [:]

    public func session(for id: UUID) -> TerminalSession? { sessions[id] }

    public func isRunning(_ id: UUID) -> Bool { sessions[id]?.isRunning ?? false }

    @discardableResult
    public func start(
        node: TerminalNode,
        command: [String],
        environment: [String: String] = [:]
    ) -> TerminalSession {
        if let existing = sessions[node.id], existing.isRunning { return existing }
        let session = TerminalSession(
            id: node.id,
            sessionID: node.sessionID,
            cwd: node.cwd,
            command: command,
            environment: environment
        )
        sessions[node.id] = session
        return session
    }

    public func stop(_ id: UUID) {
        sessions[id]?.terminate()
    }

    public func discard(_ id: UUID) {
        sessions[id]?.terminate()
        sessions[id] = nil
    }

    public func stopAll() {
        for session in sessions.values { session.terminate() }
        sessions.removeAll()
    }

    /// Session ids of terminals currently running a `claude` process, so the
    /// board can skip drawing a duplicate card for them.
    public var claimedSessionIDs: Set<String> {
        Set(sessions.values.compactMap(\.sessionID))
    }
}
