import Foundation

/// One changed file in a worktree.
public struct FileChange: Identifiable, Hashable {
    public enum Kind: String {
        case modified, added, deleted, renamed, untracked

        public var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .untracked: return "U"
            }
        }
    }

    /// Repository-relative.
    public var path: String
    public var kind: Kind
    public var additions: Int = 0
    public var deletions: Int = 0
    /// True when the change is in the index as well as (or instead of) the tree.
    public var isStaged: Bool = false

    public init(
        path: String,
        kind: Kind,
        additions: Int = 0,
        deletions: Int = 0,
        isStaged: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isStaged = isStaged
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder
    }
}

/// A parsed unified diff, ready to render.
public struct FileDiff {
    public struct Line: Identifiable, Hashable {
        public enum Kind { case context, added, removed, hunk, meta }
        public var id: Int
        public var kind: Kind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?

        public init(
            id: Int,
            kind: Kind,
            text: String,
            oldNumber: Int? = nil,
            newNumber: Int? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.oldNumber = oldNumber
            self.newNumber = newNumber
        }
    }

    public var path: String
    public var lines: [Line] = []
    public var isBinary = false
    /// Set when the diff was cut short; very large diffs are not worth rendering.
    public var truncated = false
    public var additions = 0
    public var deletions = 0

    public init(
        path: String,
        lines: [Line] = [],
        isBinary: Bool = false,
        truncated: Bool = false,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.path = path
        self.lines = lines
        self.isBinary = isBinary
        self.truncated = truncated
        self.additions = additions
        self.deletions = deletions
    }

    public var isEmpty: Bool { lines.isEmpty && !isBinary }
}

/// Turns `git diff` output into renderable lines, tracking line numbers through
/// each hunk so both sides can be labelled.
public enum DiffParser {
    /// Diffs beyond this are elided — a generated lockfile is not worth
    /// laying out thousands of SwiftUI rows for.
    public static let maxLines = 1200

    public static func parse(_ raw: String, path: String) -> FileDiff {
        var diff = FileDiff(path: path)
        guard !raw.isEmpty else { return diff }
        if raw.contains("\nBinary files ") || raw.hasPrefix("Binary files ") {
            diff.isBinary = true
            return diff
        }

        var oldLine = 0
        var newLine = 0
        var index = 0
        var started = false

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                started = true
                let numbers = Self.hunkNumbers(line)
                oldLine = numbers.old
                newLine = numbers.new
                diff.lines.append(.init(id: index, kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
                index += 1
                continue
            }
            // Everything before the first hunk is git's file header.
            guard started else { continue }

            if diff.lines.count >= maxLines {
                diff.truncated = true
                break
            }

            if line.hasPrefix("+") {
                diff.lines.append(.init(id: index, kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                diff.additions += 1
                newLine += 1
            } else if line.hasPrefix("-") {
                diff.lines.append(.init(id: index, kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                diff.deletions += 1
                oldLine += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file"
                diff.lines.append(.init(id: index, kind: .meta, text: line, oldNumber: nil, newNumber: nil))
            } else {
                let body = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                diff.lines.append(.init(id: index, kind: .context, text: body, oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
            index += 1
        }
        return diff
    }

    /// Builds an all-added diff for a file git has never seen.
    public static func forUntracked(contents: String, path: String) -> FileDiff {
        var diff = FileDiff(path: path)
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline yields a phantom empty final element; a file ending
        // in "\n" has as many lines as it has newlines, not one more.
        if lines.last?.isEmpty == true { lines.removeLast() }
        diff.lines.append(.init(id: 0, kind: .hunk, text: "@@ new file @@", oldNumber: nil, newNumber: nil))
        for (offset, line) in lines.enumerated() {
            if diff.lines.count >= maxLines { diff.truncated = true; break }
            diff.lines.append(.init(
                id: offset + 1, kind: .added, text: String(line), oldNumber: nil, newNumber: offset + 1
            ))
            diff.additions += 1
        }
        return diff
    }

    /// `@@ -12,7 +12,9 @@` → the first line number on each side.
    private static func hunkNumbers(_ header: String) -> (old: Int, new: Int) {
        var old = 1
        var new = 1
        for token in header.split(separator: " ") {
            guard token.count > 1 else { continue }
            let digits = token.dropFirst().split(separator: ",").first.flatMap { Int($0) }
            if token.hasPrefix("-"), let digits { old = digits }
            if token.hasPrefix("+"), let digits { new = digits }
        }
        return (old, new)
    }
}
