import Foundation

/// Folds session history into the repository tree and decides what each session
/// hangs off.
///
/// Most transcripts outlive the directory they ran in — Conductor workspaces are
/// removed once their branch lands, but the sessions are still worth finding.
/// Those are matched back to their repository by path shape and collected into a
/// single archived lane per repo; the session card already names its own
/// workspace, so a lane per vanished directory only added height.
struct RepoAssembler {
    struct Result {
        var repos: [Repo]
        /// Session id → the worktree path it is drawn against.
        var attachment: [String: String]
        var unattached: [SessionSummary]
    }

    func assemble(repos input: [Repo], sessions: [SessionSummary]) -> Result {
        var repos = input
        let index = WorktreeIndex(repos: repos)

        var attachment: [String: String] = [:]
        var archived: [String: Set<String>] = [:]   // repo id → vanished workspace paths
        var archivedSessions: [String: [String]] = [:]
        var unattached: [SessionSummary] = []

        // Match on the repository name and on each worktree's parent folder, so
        // `~/conductor/workspaces/backend-v3/<gone>` finds the `backend-v3` repo.
        var byName: [String: String] = [:]
        for repo in repos {
            byName[repo.name.lowercased()] = repo.id
            for worktree in repo.worktrees {
                let parent = URL(fileURLWithPath: worktree.path).deletingLastPathComponent().lastPathComponent
                if byName[parent.lowercased()] == nil { byName[parent.lowercased()] = repo.id }
            }
        }

        for session in sessions {
            let path = session.resolvedPath
            if let worktreePath = index.worktreePath(containing: path) {
                attachment[session.id] = worktreePath
                continue
            }
            guard let hint = Self.projectHint(for: path),
                  let repoID = byName[hint.lowercased()] else {
                unattached.append(session)
                continue
            }
            archived[repoID, default: []].insert(path)
            archivedSessions[repoID, default: []].append(session.id)
        }

        for (repoID, workspaces) in archived {
            guard let position = repos.firstIndex(where: { $0.id == repoID }) else { continue }
            let lanePath = Self.archivedLanePath(for: repos[position])
            repos[position].worktrees.append(
                Worktree(
                    path: lanePath,
                    branch: nil,
                    head: nil,
                    isMain: false,
                    isDetached: false,
                    isLocked: false,
                    isPrunable: false,
                    isArchived: true,
                    displayName: "Archived",
                    archivedWorkspaces: workspaces.count
                )
            )
            for sessionID in archivedSessions[repoID] ?? [] {
                attachment[sessionID] = lanePath
            }
        }

        return Result(repos: repos, attachment: attachment, unattached: unattached)
    }

    /// Synthetic path for a repo's archived lane. Prefixed so it can never
    /// collide with a real checkout, and stable so saved positions stick.
    static func archivedLanePath(for repo: Repo) -> String {
        "forge-archive:" + repo.id
    }

    static func isArchivedLane(_ path: String) -> Bool {
        path.hasPrefix("forge-archive:")
    }

    /// The project a path belongs to. Conductor nests checkouts as
    /// `…/workspaces/<project>/<workspace>`; everywhere else the last component
    /// is already the repository folder.
    static func projectHint(for path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if let marker = parts.firstIndex(of: "workspaces"), marker + 1 < parts.count {
            return parts[marker + 1]
        }
        return parts.last
    }
}

/// Finds checkouts that have no session history yet, so a repository you have
/// not used with Claude still shows up on the board.
struct WorkspaceScanner {
    /// Roots scanned two levels deep for a `.git` entry.
    static func defaultRoots() -> [String] {
        let home = NSHomeDirectory()
        return [
            home + "/conductor/workspaces",
            home + "/Documents/GitHub",
            home + "/Developer",
            home + "/src",
            home + "/code"
        ]
    }

    func candidateDirectories(roots: [String] = WorkspaceScanner.defaultRoots()) -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        for root in roots {
            guard let level1 = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for first in level1 {
                let firstPath = root + "/" + first
                guard isDirectory(firstPath) else { continue }
                if isRepo(firstPath) { found.append(firstPath) }
                guard let level2 = try? fm.contentsOfDirectory(atPath: firstPath) else { continue }
                for second in level2 {
                    let secondPath = firstPath + "/" + second
                    guard isDirectory(secondPath), isRepo(secondPath) else { continue }
                    found.append(secondPath)
                }
            }
        }
        return found
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// A linked worktree has `.git` as a file pointing at the real git dir, so
    /// testing for existence rather than directory-ness matters here.
    private func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }
}
