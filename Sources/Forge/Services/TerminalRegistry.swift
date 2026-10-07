import AppKit
import Observation
import SwiftTerm

/// One running terminal, owned by the registry rather than by a SwiftUI view.
///
/// SwiftUI rebuilds node views constantly as the canvas pans and zooms; if the
/// `LocalProcessTerminalView` were created in `makeNSView` the shell would be
/// killed and restarted every time. The view is made once here and handed back
/// on each render, so the process lives as long as the node does.
@MainActor
final class TerminalSession: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let view: LocalProcessTerminalView
    /// Type-erased handle for view code, which must not import SwiftTerm (its
    /// `Color` would shadow SwiftUI's).
    var surface: NSView { view }
    private(set) var isRunning = true
    private(set) var exitCode: Int32?
    /// Set when the terminal is running a `claude` session we pre-assigned an id to.
    let sessionID: String?

    var onExit: ((Int32?) -> Void)?

    init(id: UUID, sessionID: String?, cwd: String, command: [String], environment: [String: String]) {
        self.id = id
        self.sessionID = sessionID
        view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 380))
        super.init()

        view.processDelegate = self
        Self.style(view)

        // Run under a login shell so PATH, version managers and the user's
        // profile behave exactly as they would in Terminal.app.
        let script = "cd \(Self.quote(cwd)) || exit 1; clear; " + command.map(Self.quote).joined(separator: " ")
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        for (key, value) in environment { env.append("\(key)=\(value)") }

        view.startProcess(
            executable: Self.loginShell,
            args: ["-l", "-c", script],
            environment: env,
            execName: nil
        )
    }

    /// Visible screen contents, for diagnostics.
    var screenText: String {
        let terminal = view.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols - 1, row: rows - 1)
        )
    }

    /// Sends text as if typed. Used to give an orchestrator a follow-up task.
    func send(_ text: String) {
        view.send(txt: text)
    }

    func terminate() {
        guard isRunning else { return }
        // SIGHUP mirrors closing a terminal window: the shell tears down its
        // children rather than leaving orphaned agents behind.
        kill(view.process.shellPid, SIGHUP)
    }

    nonisolated func processTerminated(source: TerminalView, exitCode code: Int32?) {
        Task { @MainActor in
            isRunning = false
            exitCode = code
            onExit?(code)
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Match the canvas palette so a terminal reads as part of the board.
    private static func style(_ view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = NSColor(srgbRed: 0.055, green: 0.059, blue: 0.075, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0.91, green: 0.92, blue: 0.945, alpha: 1)
        view.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.caretColor = NSColor(srgbRed: 0.949, green: 0.639, blue: 0.235, alpha: 1)
    }
}

/// Holds every live terminal, keyed by its node id.
@MainActor
@Observable
final class TerminalRegistry {
    private var sessions: [UUID: TerminalSession] = [:]

    func session(for id: UUID) -> TerminalSession? { sessions[id] }

    func isRunning(_ id: UUID) -> Bool { sessions[id]?.isRunning ?? false }

    @discardableResult
    func start(
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

    func stop(_ id: UUID) {
        sessions[id]?.terminate()
    }

    func discard(_ id: UUID) {
        sessions[id]?.terminate()
        sessions[id] = nil
    }

    func stopAll() {
        for session in sessions.values { session.terminate() }
        sessions.removeAll()
    }

    /// Session ids of terminals currently running a `claude` process, so the
    /// board can skip drawing a duplicate card for them.
    var claimedSessionIDs: Set<String> {
        Set(sessions.values.compactMap(\.sessionID))
    }
}
