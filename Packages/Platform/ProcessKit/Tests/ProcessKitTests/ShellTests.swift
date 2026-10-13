import Foundation
import Testing

@testable import ProcessKit

@Suite("Shell", .serialized)
struct ShellTests {
    @Test("captures stdout and a zero status")
    func stdout() {
        let result = Shell.run("/bin/echo", ["hello"], cwd: nil)
        #expect(result.ok)
        #expect(result.status == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(!result.timedOut)
    }

    @Test("splits stdout into non-empty lines")
    func lines() {
        let result = Shell.run("/bin/sh", ["-c", "printf 'a\\n\\nb\\n'"], cwd: nil)
        #expect(result.lines == ["a", "b"])
    }

    @Test("a non-zero exit is not ok, and stderr is kept separate")
    func failure() {
        let result = Shell.run("/bin/sh", ["-c", "echo boom >&2; exit 3"], cwd: nil)
        #expect(!result.ok)
        #expect(result.status == 3)
        #expect(result.stderr.contains("boom"))
        #expect(result.stdout.isEmpty)
    }

    @Test("runs in the directory it was given")
    func cwd() throws {
        // Compared after resolving both sides: /var is a symlink to /private/var,
        // so `pwd` reports a different spelling of the same directory.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meshvy-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = Shell.run("/bin/pwd", [], cwd: directory.path)
        let reported = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(reported.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    }

    // A git call against a wedged repository used to hang the status refresh.
    @Test("a process that overruns its timeout is killed and reported")
    func timesOut() {
        let result = Shell.run("/bin/sleep", ["5"], cwd: nil, timeout: 0.3)
        #expect(result.timedOut)
        #expect(!result.ok)
    }

    @Test("an executable that is not there fails instead of trapping")
    func missingExecutable() {
        #expect(!Shell.run("/nonexistent/binary", [], cwd: nil).ok)
    }

    @Test("git resolves to something executable")
    func gitPath() {
        #expect(FileManager.default.isExecutableFile(atPath: Shell.gitPath))
    }
}
