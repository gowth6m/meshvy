import Foundation

/// Discovers checkouts and reads their state. All git calls are read-only and
/// run off the main thread; `GIT_OPTIONAL_LOCKS=0` keeps them from contending
/// with a `claude` session working in the same tree.
struct GitService {
    /// Groups a set of candidate directories into repositories keyed by their
    /// shared git dir, so every linked worktree folds into one repo.
    func discoverRepos(candidates: [String]) -> [Repo] {
        var byCommonDir: [String: String] = [:]   // commonDir -> a path inside it

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let result = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: path, timeout: 5)
            guard result.ok, let commonDir = result.lines.first, !commonDir.isEmpty else { continue }
            let resolved = URL(fileURLWithPath: commonDir).standardizedFileURL.path
            if byCommonDir[resolved] == nil { byCommonDir[resolved] = path }
        }

        return byCommonDir.compactMap { commonDir, probe in
            let worktrees = listWorktrees(cwd: probe)
            guard !worktrees.isEmpty else { return nil }
            let main = worktrees.first(where: \.isMain) ?? worktrees[0]
            return Repo(commonDir: commonDir, mainPath: main.path, worktrees: worktrees)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses `git worktree list --porcelain`. The first entry is the main
    /// working tree; the rest are linked worktrees.
    func listWorktrees(cwd: String) -> [Worktree] {
        let result = Shell.git(["worktree", "list", "--porcelain"], cwd: cwd, timeout: 6)
        guard result.ok else { return [] }

        var worktrees: [Worktree] = []
        var current: Worktree?

        func flush() {
            if let current { worktrees.append(current) }
            current = nil
        }

        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.isEmpty { flush(); continue }
            if text.hasPrefix("worktree ") {
                flush()
                let path = String(text.dropFirst("worktree ".count))
                current = Worktree(
                    path: path, branch: nil, head: nil,
                    isMain: worktrees.isEmpty, isDetached: false,
                    isLocked: false, isPrunable: false
                )
            } else if text.hasPrefix("HEAD ") {
                current?.head = String(text.dropFirst("HEAD ".count))
            } else if text.hasPrefix("branch ") {
                let ref = String(text.dropFirst("branch ".count))
                current?.branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if text == "detached" {
                current?.isDetached = true
            } else if text.hasPrefix("locked") {
                current?.isLocked = true
            } else if text.hasPrefix("prunable") {
                current?.isPrunable = true
            }
        }
        flush()
        return worktrees
    }

    /// Second, slower pass: dirty counts, upstream divergence, and the tip
    /// commit. Separated so the canvas can draw worktrees immediately.
    func status(for worktree: Worktree) -> Worktree {
        var result = worktree
        let path = worktree.path
        guard !worktree.isArchived else { return result }
        guard FileManager.default.fileExists(atPath: path) else {
            result.dirtyFiles = 0
            result.untrackedFiles = 0
            return result
        }

        let status = Shell.git(["status", "--porcelain=v1", "--untracked-files=normal"], cwd: path, timeout: 10)
        if status.ok {
            var tracked = 0
            var untracked = 0
            for line in status.lines {
                if line.hasPrefix("??") { untracked += 1 } else { tracked += 1 }
            }
            result.dirtyFiles = tracked
            result.untrackedFiles = untracked
        } else {
            result.dirtyFiles = 0
            result.untrackedFiles = 0
        }

        let upstream = Shell.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], cwd: path, timeout: 5)
        if upstream.ok, let name = upstream.lines.first, !name.isEmpty {
            result.upstream = name
            let counts = Shell.git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], cwd: path, timeout: 8)
            if counts.ok, let line = counts.lines.first {
                let parts = line.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
                if parts.count == 2 {
                    result.behind = parts[0]
                    result.ahead = parts[1]
                }
            }
        }

        // Unit separator between fields keeps subjects containing anything safe.
        let log = Shell.git(["log", "-1", "--format=%s%x1f%ct%x1f%an"], cwd: path, timeout: 6)
        if log.ok, let line = log.lines.first {
            let parts = line.components(separatedBy: "\u{1f}")
            if parts.count == 3 {
                result.lastCommitSubject = parts[0]
                result.lastCommitDate = Double(parts[1]).map { Date(timeIntervalSince1970: $0) }
                result.lastCommitAuthor = parts[2]
            }
        }

        return result
    }

    // MARK: - Changes

    /// Files changed in a worktree relative to HEAD, including untracked ones.
    ///
    /// `-uall` matters: without it git collapses an untracked directory into a
    /// single `?? dir/` entry and you cannot list what is actually inside.
    func changes(at path: String) -> [FileChange] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var counts: [String: (added: Int, removed: Int)] = [:]
        let numstat = Shell.git(
            ["-c", "core.quotepath=false", "diff", "--numstat", "HEAD"], cwd: path, timeout: 15
        )
        if numstat.ok {
            for line in numstat.lines {
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                counts[String(parts[2])] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
            }
        }

        let status = Shell.git(
            ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-uall"], cwd: path, timeout: 15
        )
        guard status.ok else { return [] }

        var changes: [FileChange] = []
        var seen = Set<String>()
        for line in status.lines {
            guard line.count > 3 else { continue }
            let codes = String(line.prefix(2))
            var file = String(line.dropFirst(3))
            // Renames read as "old -> new"; the new path is what we diff.
            if let arrow = file.range(of: " -> ") {
                file = String(file[arrow.upperBound...])
            }
            guard seen.insert(file).inserted else { continue }

            let kind: FileChange.Kind
            if codes.hasPrefix("??") { kind = .untracked }
            else if codes.contains("R") { kind = .renamed }
            else if codes.contains("A") { kind = .added }
            else if codes.contains("D") { kind = .deleted }
            else { kind = .modified }

            let count = counts[file]
            changes.append(FileChange(
                path: file,
                kind: kind,
                additions: count?.added ?? 0,
                deletions: count?.removed ?? 0,
                isStaged: codes.first != " " && codes.first != "?"
            ))
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// The unified diff for one file, or a synthesised all-added diff when the
    /// file is untracked and git has nothing to compare it against.
    func diff(at path: String, file: FileChange) -> FileDiff {
        if file.kind == .untracked {
            let url = URL(fileURLWithPath: path).appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: url),
                  data.count < 2_000_000,
                  let text = String(data: data, encoding: .utf8)
            else {
                var diff = FileDiff(path: file.path)
                diff.isBinary = true
                return diff
            }
            return DiffParser.forUntracked(contents: text, path: file.path)
        }

        let result = Shell.git(
            ["-c", "core.quotepath=false", "diff", "HEAD", "--", file.path], cwd: path, timeout: 20
        )
        guard result.ok else { return FileDiff(path: file.path) }
        return DiffParser.parse(result.stdout, path: file.path)
    }
}
