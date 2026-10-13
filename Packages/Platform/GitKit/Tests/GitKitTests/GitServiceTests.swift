import Foundation
import MeshvyModels
import ProcessKit
import Testing

@testable import GitKit

/// A throwaway repository on disk. GitKit shells out to the real `git`, so
/// these are integration tests against a real checkout rather than a stub —
/// a fake would only prove that the fake behaves like the fake.
private struct Scratch: ~Copyable {
    let path: String

    init(commit: Bool = true) {
        path = NSTemporaryDirectory() + "meshvy-git-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        Shell.git(["init", "-q", "-b", "main"], cwd: path)
        Shell.git(["config", "user.email", "test@example.com"], cwd: path)
        Shell.git(["config", "user.name", "Test"], cwd: path)
        if commit {
            write("README.md", "hello\n")
            Shell.git(["add", "-A"], cwd: path)
            Shell.git(["commit", "-q", "-m", "first"], cwd: path)
        }
    }

    func write(_ name: String, _ contents: String) {
        try? contents.write(toFile: path + "/" + name, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

@Suite("GitService", .serialized)
struct GitServiceTests {
    private let git = GitService()

    @Test("a real checkout is discovered as one repository")
    func discoversRepo() {
        let scratch = Scratch()
        let repos = git.discoverRepos(candidates: [scratch.path])
        #expect(repos.count == 1)
        #expect(repos.first?.worktrees.isEmpty == false)
    }

    @Test("a directory that is not a repository is skipped, not reported empty")
    func ignoresNonRepo() {
        let plain = NSTemporaryDirectory() + "meshvy-plain-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        #expect(git.discoverRepos(candidates: [plain]).isEmpty)
    }

    @Test("a path that does not exist is skipped")
    func ignoresMissingPath() {
        #expect(git.discoverRepos(candidates: ["/nonexistent/\(UUID().uuidString)"]).isEmpty)
    }

    // Every linked worktree shares one `--git-common-dir`, which is what folds
    // them into a single repository on the board instead of several.
    @Test("two checkouts of one repository fold into a single repo")
    func foldsWorktrees() {
        let scratch = Scratch()
        let linked = scratch.path + "-wt"
        Shell.git(["worktree", "add", "-q", "-b", "side", linked], cwd: scratch.path)
        defer {
            Shell.git(["worktree", "remove", "--force", linked], cwd: scratch.path)
            try? FileManager.default.removeItem(atPath: linked)
        }
        let repos = git.discoverRepos(candidates: [scratch.path, linked])
        #expect(repos.count == 1)
        #expect((repos.first?.worktrees.count ?? 0) >= 2)
    }

    @Test("the main worktree knows its branch")
    func readsBranch() {
        let scratch = Scratch()
        let main = git.discoverRepos(candidates: [scratch.path]).first?
            .worktrees.first { $0.isMain }
        #expect(main?.branch == "main")
        #expect(main?.isDetached == false)
    }

    @Test("a repository with no commits yet does not crash discovery")
    func emptyRepo() {
        let scratch = Scratch(commit: false)
        #expect(git.discoverRepos(candidates: [scratch.path]).count == 1)
    }
}
