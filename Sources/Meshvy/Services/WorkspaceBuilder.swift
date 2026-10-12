import Foundation

/// Creates and tears down the worktrees that make up a workspace.
///
/// Creating a workspace is one step: pick repositories and a base, and every
/// repository gets a checkout of the same new branch under `~/.meshvy/<slug>/`.
/// Repositories are handled independently — if one fails the others still get
/// their checkout, and the failure is recorded against that repo.
struct WorkspaceBuilder {
    private let git = GitService()

    // MARK: - Inspecting candidates

    /// Resolves a folder the user picked into a repository we can cut from.
    func inspectRepo(at path: String) -> WorkspaceRepo? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let common = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: resolved, timeout: 6)
        guard common.ok, let commonDir = common.lines.first, !commonDir.isEmpty else { return nil }

        // Always record the main working tree, even if a linked one was picked.
        let worktrees = git.listWorktrees(cwd: resolved)
        let originPath = worktrees.first(where: \.isMain)?.path ?? resolved
        let name = URL(fileURLWithPath: originPath).lastPathComponent

        return WorkspaceRepo(
            id: URL(fileURLWithPath: commonDir).standardizedFileURL.path,
            name: name,
            originPath: originPath,
            worktreePath: ""
        )
    }

    /// Branches available to cut from, newest-looking first.
    func branches(for repos: [WorkspaceRepo]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for repo in repos {
            if let preferred = defaultBranch(for: repo.originPath), seen.insert(preferred).inserted {
                ordered.append(preferred)
            }
        }
        for repo in repos {
            let listed = Shell.git(
                ["for-each-ref", "--format=%(refname:short)", "--sort=-committerdate", "refs/heads", "--count=40"],
                cwd: repo.originPath, timeout: 8
            )
            guard listed.ok else { continue }
            for name in listed.lines where seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }

    /// Where a new branch is cut from: the remote's default when known, else a
    /// conventional name, else whatever HEAD points at.
    func defaultBranch(for repoPath: String) -> String? {
        let remote = Shell.git(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], cwd: repoPath, timeout: 5
        )
        if remote.ok, let line = remote.lines.first, !line.isEmpty {
            return line.replacingOccurrences(of: "origin/", with: "")
        }
        for candidate in ["main", "master", "develop", "dev"]
        where Shell.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + candidate], cwd: repoPath, timeout: 4).ok {
            return candidate
        }
        let head = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repoPath, timeout: 4)
        return head.ok ? head.lines.first : nil
    }

    // MARK: - Building

    /// Cuts `branch` in every repository and checks it out under the workspace
    /// root. Returns the workspace with each repo's outcome recorded.
    func build(
        name: String,
        branch: String,
        baseRef: String?,
        repos: [WorkspaceRepo]
    ) -> Workspace {
        let root = Workspace.root(for: name)
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        var workspace = Workspace(name: name, branch: branch, baseRef: baseRef, root: root)
        workspace.repos = repos.map { repo in
            var copy = repo
            copy.worktreePath = root + "/" + repo.name
            let base = baseRef ?? defaultBranch(for: repo.originPath) ?? "HEAD"
            copy.failure = addWorktree(
                repoPath: repo.originPath,
                destination: copy.worktreePath,
                branch: branch,
                baseRef: base
            )
            return copy
        }
        return workspace
    }

    /// Adds one checkout. Returns nil on success, or a one-line reason.
    private func addWorktree(repoPath: String, destination: String, branch: String, baseRef: String) -> String? {
        if FileManager.default.fileExists(atPath: destination) {
            // Already checked out here: fine if git agrees it is ours.
            let known = git.listWorktrees(cwd: repoPath).contains { $0.path == destination }
            return known ? nil : "\(destination) already exists"
        }

        let branchExists = Shell.git(
            ["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], cwd: repoPath, timeout: 6
        ).ok
        let arguments: [String] = branchExists
            ? ["worktree", "add", destination, branch]
            : ["worktree", "add", "-b", branch, destination, baseRef]

        let result = Shell.git(arguments, cwd: repoPath, timeout: 120)
        guard result.ok else {
            return Self.firstLine(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return nil
    }

    /// Adds repositories to a workspace that already exists.
    func extend(_ workspace: Workspace, with repos: [WorkspaceRepo]) -> Workspace {
        var updated = workspace
        let existing = Set(workspace.repos.map(\.id))
        for repo in repos where !existing.contains(repo.id) {
            var copy = repo
            copy.worktreePath = workspace.root + "/" + repo.name
            let base = workspace.baseRef ?? defaultBranch(for: repo.originPath) ?? "HEAD"
            copy.failure = addWorktree(
                repoPath: repo.originPath,
                destination: copy.worktreePath,
                branch: workspace.branch,
                baseRef: base
            )
            updated.repos.append(copy)
        }
        return updated
    }

    // MARK: - Tearing down

    /// Removes every checkout. `force` discards uncommitted work; without it git
    /// refuses on a dirty tree and that repository is reported back.
    func tearDown(_ workspace: Workspace, force: Bool, deleteBranch: Bool) -> [String] {
        var failures: [String] = []

        for repo in workspace.repos where FileManager.default.fileExists(atPath: repo.worktreePath) {
            var arguments = ["worktree", "remove", repo.worktreePath]
            if force { arguments.append("--force") }
            let result = Shell.git(arguments, cwd: repo.originPath, timeout: 60)
            if !result.ok {
                failures.append("\(repo.name): \(Self.firstLine(result.stderr))")
                continue
            }
            if deleteBranch {
                let deleted = Shell.git(["branch", force ? "-D" : "-d", workspace.branch], cwd: repo.originPath, timeout: 20)
                if !deleted.ok {
                    failures.append("\(repo.name): branch kept — \(Self.firstLine(deleted.stderr))")
                }
            }
        }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: workspace.root), contents.isEmpty {
            try? FileManager.default.removeItem(atPath: workspace.root)
        }
        return failures
    }

    // MARK: - Cloning

    enum CloneResult {
        case cloned(WorkspaceRepo)
        case failed(String)
    }

    /// Clones a remote into `~/.meshvy/repos` and returns it ready to add.
    func clone(_ reference: String) -> CloneResult {
        let directory = Workspace.meshvyHome + "/repos"
        let url = Self.normalizeRemote(reference)
        let destination = directory + "/" + Self.repoName(from: url)

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
        let parts = trimmed.split(separator: "/")
        return parts.count == 2 ? "https://github.com/\(trimmed).git" : trimmed
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
