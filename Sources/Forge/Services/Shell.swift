import Foundation

/// Minimal process runner for the handful of `git` invocations the app makes.
/// Everything is read-only; nothing here mutates a repository.
enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
        var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }
    }

    /// Resolved once — Homebrew git is preferred when present, else Apple git.
    static let gitPath: String = {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    @discardableResult
    static func git(_ arguments: [String], cwd: String?, timeout: TimeInterval = 8) -> Result {
        run(gitPath, arguments, cwd: cwd, timeout: timeout)
    }

    static func run(_ executable: String, _ arguments: [String], cwd: String?, timeout: TimeInterval = 8) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        // Keep git from touching a terminal, prompting for credentials, or
        // picking up the user's pager.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return Result(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        // Drain both pipes concurrently; a full 64 KB pipe buffer would otherwise
        // deadlock against `waitUntilExit`.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let ioQueue = DispatchQueue(label: "forge.shell.io", attributes: .concurrent)
        let lock = NSLock()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            ioQueue.async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                timedOut = true
                break
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        group.wait()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData),
            stderr: String(decoding: errData),
            timedOut: timedOut
        )
    }
}

private extension String {
    /// git output is usually UTF-8 but filenames can be arbitrary bytes.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
