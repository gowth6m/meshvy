import Foundation

/// One headless `claude -p` drawing or refreshing a workspace's map.
///
/// Claude's output is read as `stream-json`, one event per line, and turned
/// into a short line of progress ("Scanning the repositories", "Reading
/// api/src/server.js") for the workspace node to show. Nothing waits on it:
/// `onProgress` and `onFinish` are called on the main queue.
public final class MapRun {
    public enum Outcome: Equatable {
        case finished(report: String)
        case failed(String)
        case stopped
    }

    public let root: String
    public private(set) var progress = "Starting Claude"
    public private(set) var isRunning = false

    public var onProgress: ((String) -> Void)?
    public var onFinish: ((Outcome) -> Void)?

    private let process = Process()
    private var buffer = Data()
    private var report: String?
    private var error: String?
    private var stderrTail = ""
    private var wasStopped = false

    /// - Parameters:
    ///   - claudePath: the `claude` to run.
    ///   - node: the `node` the engine's scripts run with; its folder goes
    ///     first on the run's PATH so `node` in a command finds it.
    ///   - model: the model to use, or nil for Claude Code's default.
    public init(
        root: String,
        skillDirectory: String,
        claudePath: String,
        node: String,
        refresh: Bool,
        model: String? = nil
    ) {
        self.root = root
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.arguments = MapRun.arguments(skillDirectory: skillDirectory, model: model)
        var environment = ProcessInfo.processInfo.environment
        let nodeFolder = (node as NSString).deletingLastPathComponent
        environment["PATH"] = nodeFolder + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        prompt = Floorplan.task(skillDirectory: skillDirectory, root: root, refresh: refresh)
    }

    private let prompt: String

    /// The argv after `claude`. The prompt goes in on stdin, so the variadic
    /// `--allowedTools` cannot swallow it.
    public static func arguments(skillDirectory: String, model: String?) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose",
                         "--permission-mode", "acceptEdits"]
        if let model { arguments.append(contentsOf: ["--model", model]) }
        arguments.append("--allowedTools")
        arguments.append(contentsOf: Floorplan.allowedTools(skillDirectory: skillDirectory))
        return arguments
    }

    public func start() {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // The pipes call back on their own threads; everything is handed to
        // the main queue, where all of this object's state lives.
        let weakSelf = WeakRun(self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async { weakSelf.run?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let run = weakSelf.run else { return }
                run.stderrTail = String((run.stderrTail + text).suffix(2000))
            }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            // The last lines, the result among them, can still be in the pipe.
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let run = weakSelf.run else { return }
                run.receive(rest)
                run.receive(Data("\n".utf8))
                run.finish(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            finish(launchError: "Could not start Claude: \(error.localizedDescription)")
            return
        }
        isRunning = true
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
    }

    public func stop() {
        guard isRunning else { return }
        wasStopped = true
        process.terminate()
    }

    // MARK: - Reading the stream

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let event = MapRun.parse(line) else { return }
        switch event {
        case .progress(let text):
            progress = text
            onProgress?(text)
        case .result(let text, let isError):
            if isError { error = text } else { report = text }
        }
    }

    enum Event: Equatable {
        case progress(String)
        case result(String, isError: Bool)
    }

    /// One `stream-json` line, as progress or as the final result. Nil for
    /// anything not worth showing.
    static func parse(_ line: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "result" {
            let isError = (object["is_error"] as? Bool) ?? ((object["subtype"] as? String) != "success")
            let text = (object["result"] as? String) ?? (object["subtype"] as? String) ?? ""
            return .result(text, isError: isError)
        }
        guard type == "assistant",
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for block in content.reversed() where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            let input = block["input"] as? [String: Any] ?? [:]
            if let text = describe(tool: name, input: input) { return .progress(text) }
        }
        return nil
    }

    /// A tool call, in words.
    static func describe(tool: String, input: [String: Any]) -> String? {
        let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            let command = input["command"] as? String ?? ""
            let steps: [(String, String)] = [
                ("scan.mjs", "Scanning the repositories"),
                ("refresh.mjs", "Finding what changed"),
                ("build.mjs", "Building the map"),
                ("describe.mjs", "Preparing descriptions"),
                ("recent.mjs", "Looking at recent work"),
                ("status.mjs", "Checking for an earlier map"),
                ("plan.mjs", "Reading the plan"),
            ]
            for (script, words) in steps where command.contains("/scripts/" + script) { return words }
            return "Running a command"
        case "Read": return file.map { "Reading \($0)" } ?? "Reading the code"
        case "Write", "Edit": return file.map { "Writing \($0)" } ?? "Writing the map"
        case "Grep", "Glob": return "Searching the code"
        case "Task", "Agent": return "Describing parts in parallel"
        default: return nil
        }
    }

    // MARK: - Finishing

    private func finish(launchError: String) {
        isRunning = false
        onFinish?(.failed(launchError))
    }

    private func finish(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        if wasStopped {
            onFinish?(.stopped)
        } else if status == 0, error == nil, Floorplan.hasMap(root: root) {
            onFinish?(.finished(report: report ?? ""))
        } else {
            let detail = error
                ?? stderrTail.split(separator: "\n").last.map(String.init)
                ?? (Floorplan.hasMap(root: root) ? "Claude stopped early." : "Claude finished without building a map.")
            onFinish?(.failed(detail))
        }
    }
}

/// A weak reference the pipe callbacks can hold: they run on other threads,
/// and only ever hand the run back to the main queue.
private final class WeakRun: @unchecked Sendable {
    weak var run: MapRun?
    init(_ run: MapRun) { self.run = run }
}
