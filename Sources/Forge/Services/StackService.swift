import Foundation

/// Creates and removes the linked worktrees that make up a stack.
///
/// A stack is one branch name realised as a worktree in every repo of the
/// workspace, so a change spanning several repos is one unit of work. Repos are
/// handled independently: if one fails, the others still get their checkout and
/// the failure is recorded against that member rather than aborting everything.
struct StackService {
    private let git = GitService()

    struct Outcome {
        var stack: Stack
        var failures: [String]
        var succeeded: Bool { failures.isEmpty }
    }

    // MARK: - Creating

    func createStack(
        name: String,
        branch: String,
        baseRef: String?,
        intent: String?,
        in workspace: Workspace
    ) -> Outcome {
        var members: [StackMember] = []
        var failures: [String] = []
        let stackFolder = workspace.worktreeRoot + "/" + Workspace.slug(name)

        for repo in workspace.repos {
            let destination = stackFolder + "/" + repo.name
            let base = baseRef ?? repo.defaultBranch ?? defaultBranch(for: repo.path) ?? "HEAD"
            let result = addWorktree(repoPath: repo.path, destination: destination, branch: branch, baseRef: base)

            switch result {
            case .success:
                members.append(StackMember(repoID: repo.id, repoName: repo.name, path: destination))
            case .failure(let message):
                failures.append("\(repo.name): \(message)")
                members.append(StackMember(
                    repoID: repo.id, repoName: repo.name, path: destination, failure: message
                ))
            }
        }

        let stack = Stack(
            name: name,
            branch: branch,
            baseRef: baseRef,
            members: members,
            intent: intent?.isEmpty == true ? nil : intent
        )
        return Outcome(stack: stack, failures: failures)
    }

    private enum AddResult {
        case success
        case failure(String)
    }

    /// `git worktree add`, reusing the branch when it already exists so a stack
    /// can be recreated or extended to a repo added later.
    private func addWorktree(repoPath: String, destination: String, branch: String, baseRef: String) -> AddResult {
        if FileManager.default.fileExists(atPath: destination) {
            // Already checked out here — treat as success if git agrees it is a
            // worktree of this repo, otherwise refuse to clobber it.
            let known = git.listWorktrees(cwd: repoPath).contains { $0.path == destination }
            return known ? .success : .failure("\(destination) already exists")
        }

        try? FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        let branchExists = Shell.git(
            ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], cwd: repoPath, timeout: 6
        ).ok

        let arguments: [String] = branchExists
            ? ["worktree", "add", destination, branch]
            : ["worktree", "add", "-b", branch, destination, baseRef]

        let result = Shell.git(arguments, cwd: repoPath, timeout: 120)
        guard result.ok else {
            return .failure(Self.firstLine(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return .success
    }

    /// The branch a new stack is cut from: the remote's default when known,
    /// else a conventional name, else whatever HEAD points at.
    func defaultBranch(for repoPath: String) -> String? {
        let remote = Shell.git(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], cwd: repoPath, timeout: 5
        )
        if remote.ok, let line = remote.lines.first, !line.isEmpty {
            return line.replacingOccurrences(of: "origin/", with: "")
        }
        for candidate in ["main", "master", "develop", "dev"] {
            if Shell.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + candidate], cwd: repoPath, timeout: 4).ok {
                return candidate
            }
        }
        let head = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath, timeout: 4)
        return head.ok ? head.lines.first : nil
    }

    // MARK: - Removing

    /// Removes every worktree in the stack. `force` discards uncommitted work;
    /// without it git refuses on a dirty tree and that repo is reported back.
    func removeStack(_ stack: Stack, in workspace: Workspace, force: Bool, deleteBranch: Bool) -> [String] {
        var failures: [String] = []

        for member in stack.members {
            guard let repo = workspace.repos.first(where: { $0.id == member.repoID }) else { continue }
            guard FileManager.default.fileExists(atPath: member.path) else { continue }

            var arguments = ["worktree", "remove", member.path]
            if force { arguments.append("--force") }
            let result = Shell.git(arguments, cwd: repo.path, timeout: 60)
            if !result.ok {
                failures.append("\(member.repoName): \(Self.firstLine(result.stderr))")
                continue
            }
            if deleteBranch {
                let flag = force ? "-D" : "-d"
                let deleted = Shell.git(["branch", flag, stack.branch], cwd: repo.path, timeout: 20)
                if !deleted.ok {
                    failures.append("\(member.repoName): branch not deleted — \(Self.firstLine(deleted.stderr))")
                }
            }
        }

        // Clean up the now-empty stack folder.
        let folder = workspace.worktreeRoot + "/" + Workspace.slug(stack.name)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: folder), contents.isEmpty {
            try? FileManager.default.removeItem(atPath: folder)
        }
        return failures
    }

    // MARK: - Adding repositories

    /// Resolves a folder the user picked into a repository we can track.
    func inspectRepo(at path: String) -> WorkspaceRepo? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let common = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: resolved, timeout: 6)
        guard common.ok, let commonDir = common.lines.first, !commonDir.isEmpty else { return nil }

        // Always record the main working tree, even if the user picked a linked one.
        let worktrees = git.listWorktrees(cwd: resolved)
        let mainPath = worktrees.first(where: \.isMain)?.path ?? resolved
        let id = URL(fileURLWithPath: commonDir).standardizedFileURL.path

        return WorkspaceRepo(
            id: id,
            path: mainPath,
            name: URL(fileURLWithPath: mainPath).lastPathComponent,
            defaultBranch: defaultBranch(for: mainPath)
        )
    }

    /// Clones a remote into the workspace's checkout root. Accepts the forms
    /// GitHub hands out plus `owner/repo` shorthand.
    enum CloneResult {
        case cloned(WorkspaceRepo)
        case failed(String)
    }

    func clone(_ reference: String, into directory: String) -> CloneResult {
        let url = Self.normalizeRemote(reference)
        let name = Self.repoName(from: url)
        let destination = directory + "/" + name

        if FileManager.default.fileExists(atPath: destination) {
            guard let existing = inspectRepo(at: destination) else {
                return .failed("\(destination) exists and is not a git repository")
            }
            return .cloned(existing)
        }

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let result = Shell.git(["clone", url, destination], cwd: directory, timeout: 600)
        guard result.ok else {
            return .failed(Self.firstLine(result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        guard let repo = inspectRepo(at: destination) else {
            return .failed("cloned, but \(destination) does not look like a repository")
        }
        return .cloned(repo)
    }

    static func normalizeRemote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("git@") { return trimmed }
        // `owner/repo` shorthand.
        let parts = trimmed.split(separator: "/")
        if parts.count == 2 { return "https://github.com/\(trimmed).git" }
        return trimmed
    }

    static func repoName(from url: String) -> String {
        var name = url
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? "repo" : name
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "failed"
    }
}
