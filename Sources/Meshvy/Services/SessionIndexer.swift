import Foundation

// Needles are allocated once at module scope; `memmem` needs a stable pointer
// and these are hit millions of times across a full index pass.
private let nAssistant = StaticNeedle(#""type":"assistant""#)
private let nUser = StaticNeedle(#""type":"user""#)
private let nAITitle = StaticNeedle(#""type":"ai-title""#)
private let nToolUse = StaticNeedle(#""type":"tool_use""#)
private let nToolUseID = StaticNeedle(#""tool_use_id""#)
private let nCwd = StaticNeedle(#""cwd":""#)
private let nBranch = StaticNeedle(#""gitBranch":""#)
private let nVersion = StaticNeedle(#""version":""#)
private let nModel = StaticNeedle(#""model":""#)
private let nTitleValue = StaticNeedle(#""aiTitle":""#)
private let nTimestamp = StaticNeedle(#""timestamp":""#)
private let nSidechainTrue = StaticNeedle(#""isSidechain":true"#)
private let nInputTokens = StaticNeedle(#""input_tokens":"#)
private let nCacheRead = StaticNeedle(#""cache_read_input_tokens":"#)
private let nCacheCreate = StaticNeedle(#""cache_creation_input_tokens":"#)

/// Persisted result of scanning one transcript, so relaunches are instant and
/// growing files only re-scan the appended bytes.
struct IndexCache: Codable {
    static let currentVersion = 3

    struct Entry: Codable {
        var sessionId: String
        var fileSize: Int64
        var modified: Double
        /// Offset up to which counts are already accumulated, on a line boundary.
        var scannedBytes: Int

        var cwd: String?
        var gitBranch: String?
        var cliVersion: String?
        var model: String?
        var aiTitle: String?
        var firstPrompt: String?
        var startedAt: Double?

        var humanTurns: Int = 0
        var assistantTurns: Int = 0
        var toolCalls: Int = 0
        var contextTokens: Int = 0
        var isSidechain: Bool = false
    }

    var version: Int = IndexCache.currentVersion
    var entries: [String: Entry] = [:]
}

/// Builds `SessionSummary` values for every transcript under `~/.claude/projects`.
///
/// Deliberately avoids `JSONSerialization` on the bulk of the data: the store
/// here is ~400 MB across 145 files and a full decode takes tens of seconds,
/// while a byte scan takes well under one.
final class SessionIndexer {
    private let rootURL: URL
    private let cacheStore = FileStore<IndexCache>(filename: "session-index.json")
    private var cache: IndexCache

    init(root: URL? = nil) {
        rootURL = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let loaded = cacheStore.load()
        cache = (loaded?.version == IndexCache.currentVersion) ? loaded! : IndexCache()
    }

    /// Transcript files on disk, newest first.
    func transcriptFiles() -> [URL] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for dir in projectDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let contents = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            files.append(contentsOf: contents.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    /// Indexes every transcript. `onBatch` fires as results land so the canvas
    /// can populate progressively instead of waiting for the slowest file.
    func index(files: [URL], onBatch: @escaping ([SessionSummary]) -> Void) {
        let lock = NSLock()
        var updated: [String: IndexCache.Entry] = [:]
        let batchSize = 12

        // Work the biggest files first so the long tail is not last.
        let ordered = files.sorted { (fileSize($0) ?? 0) > (fileSize($1) ?? 0) }
        var pending: [SessionSummary] = []

        DispatchQueue.concurrentPerform(iterations: ordered.count) { position in
            let url = ordered[position]
            guard let entry = self.entry(for: url) else { return }
            let summary = SessionIndexer.summary(from: entry, url: url)
            lock.lock()
            updated[url.path] = entry
            pending.append(summary)
            let flush = pending.count >= batchSize ? pending : nil
            if flush != nil { pending.removeAll(keepingCapacity: true) }
            lock.unlock()
            if let flush { onBatch(flush) }
        }

        lock.lock()
        let tail = pending
        pending.removeAll()
        cache.entries = updated
        lock.unlock()
        if !tail.isEmpty { onBatch(tail) }
        cacheStore.save(cache)
    }

    /// Cheap pass that returns one summary per file using only filesystem
    /// metadata plus whatever the cache already holds. Lets the first frame draw
    /// before any scanning happens.
    func quickSummaries(files: [URL]) -> [SessionSummary] {
        files.compactMap { url in
            let sessionId = url.deletingPathExtension().lastPathComponent
            if let cached = cache.entries[url.path],
               cached.fileSize == (fileSize(url) ?? -1),
               cached.modified == (modified(url)?.timeIntervalSince1970 ?? -1) {
                return SessionIndexer.summary(from: cached, url: url)
            }
            var summary = SessionSummary(
                id: sessionId,
                fileURL: url,
                projectDirName: url.deletingLastPathComponent().lastPathComponent,
                lastActivityAt: modified(url) ?? .distantPast,
                fileSize: fileSize(url) ?? 0
            )
            summary.isIndexed = false
            return summary
        }
    }

    // MARK: - Scanning

    private func entry(for url: URL) -> IndexCache.Entry? {
        guard let size = fileSize(url), let mtime = modified(url) else { return nil }
        let sessionId = url.deletingPathExtension().lastPathComponent
        let existing = cache.entries[url.path]

        if let existing, existing.fileSize == size, existing.modified == mtime.timeIntervalSince1970 {
            return existing
        }

        // Transcripts are append-only, so when the file has only grown we can
        // resume from the last complete record instead of re-reading from zero.
        let resumable = existing.flatMap { prior -> IndexCache.Entry? in
            guard Int64(prior.scannedBytes) <= size, prior.scannedBytes > 0 else { return nil }
            return prior
        }

        var entry = resumable ?? IndexCache.Entry(
            sessionId: sessionId, fileSize: size, modified: mtime.timeIntervalSince1970, scannedBytes: 0
        )
        entry.fileSize = size
        entry.modified = mtime.timeIntervalSince1970

        guard let data = try? JSONLScanner.map(url) else { return entry }

        var counts = Counts()
        var marks = Marks()
        let consumed = JSONLScanner.scan(data, from: entry.scannedBytes) { line in
            SessionIndexer.classify(line, counts: &counts, marks: &marks)
        }

        entry.humanTurns += counts.humanTurns
        entry.assistantTurns += counts.assistantTurns
        entry.toolCalls += counts.toolCalls
        entry.scannedBytes = consumed
        if counts.sawSidechain { entry.isSidechain = true }

        // Targeted field extraction: re-visit only the few lines that matter.
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            func view(_ mark: Mark?) -> LineView? {
                guard let mark, mark.offset + mark.length <= raw.count else { return nil }
                return LineView(base: base + mark.offset, count: mark.length)
            }

            if let line = view(marks.firstContext) {
                if entry.cwd == nil { entry.cwd = line.string(after: nCwd) }
                if entry.gitBranch == nil { entry.gitBranch = line.string(after: nBranch) }
                if entry.cliVersion == nil { entry.cliVersion = line.string(after: nVersion) }
            }
            if let line = view(marks.lastAITitle), let title = line.string(after: nTitleValue) {
                entry.aiTitle = title
            }
            if let line = view(marks.lastAssistant) {
                entry.model = line.string(after: nModel) ?? entry.model
                let input = line.int(after: nInputTokens) ?? 0
                let cacheRead = line.int(after: nCacheRead) ?? 0
                let cacheCreate = line.int(after: nCacheCreate) ?? 0
                let context = input + cacheRead + cacheCreate
                if context > 0 { entry.contextTokens = context }
            }
            if entry.startedAt == nil, let line = view(marks.firstTimestamp),
               let stamp = line.string(after: nTimestamp),
               let date = ISO8601DateFormatter.transcript.date(from: stamp) {
                entry.startedAt = date.timeIntervalSince1970
            }
            if entry.firstPrompt == nil, let line = view(marks.firstHumanTurn) {
                entry.firstPrompt = SessionIndexer.extractPrompt(from: line)
            }
        }

        return entry
    }

    private struct Counts {
        var humanTurns = 0
        var assistantTurns = 0
        var toolCalls = 0
        var sawSidechain = false
    }

    private struct Mark { var offset: Int; var length: Int }

    private struct Marks {
        var firstContext: Mark?
        var firstTimestamp: Mark?
        var firstHumanTurn: Mark?
        var lastAssistant: Mark?
        var lastAITitle: Mark?
    }

    /// One pass over a line. Ordered cheapest-discriminator first; tool-result
    /// payload lines are the bulk of the bytes so they exit after two probes.
    private static func classify(_ line: LineView, counts: inout Counts, marks: inout Marks) {
        // `LineView.base` is only valid for this call, so marks store file
        // offsets and the view is re-created in a second pass.
        if line.contains(nAssistant) {
            counts.assistantTurns += 1
            counts.toolCalls += line.occurrences(of: nToolUse)
            marks.lastAssistant = Mark(offset: line.offsetInFile, length: line.count)
            if marks.firstContext == nil, line.contains(nCwd) {
                marks.firstContext = Mark(offset: line.offsetInFile, length: line.count)
            }
            if marks.firstTimestamp == nil, line.contains(nTimestamp) {
                marks.firstTimestamp = Mark(offset: line.offsetInFile, length: line.count)
            }
            return
        }

        if line.contains(nUser) {
            if line.contains(nToolUseID) {
                // Tool output delivered as a user turn — not a human prompt.
            } else {
                counts.humanTurns += 1
                if marks.firstHumanTurn == nil {
                    marks.firstHumanTurn = Mark(offset: line.offsetInFile, length: line.count)
                }
            }
            if line.contains(nSidechainTrue) { counts.sawSidechain = true }
            if marks.firstContext == nil, line.contains(nCwd) {
                marks.firstContext = Mark(offset: line.offsetInFile, length: line.count)
            }
            if marks.firstTimestamp == nil, line.contains(nTimestamp) {
                marks.firstTimestamp = Mark(offset: line.offsetInFile, length: line.count)
            }
            return
        }

        if line.contains(nAITitle) {
            marks.lastAITitle = Mark(offset: line.offsetInFile, length: line.count)
            return
        }

        if marks.firstTimestamp == nil, line.contains(nTimestamp) {
            marks.firstTimestamp = Mark(offset: line.offsetInFile, length: line.count)
        }
    }

    /// Human prompts arrive wrapped in harness scaffolding; show the part a
    /// person actually typed.
    private static func extractPrompt(from line: LineView) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
              let message = object["message"] as? [String: Any] else { return nil }
        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return text.map { PromptCleaner.clean($0) }
    }

    // MARK: - Helpers

    private static func summary(from entry: IndexCache.Entry, url: URL) -> SessionSummary {
        var summary = SessionSummary(
            id: entry.sessionId,
            fileURL: url,
            projectDirName: url.deletingLastPathComponent().lastPathComponent,
            cwd: entry.cwd,
            gitBranch: entry.gitBranch,
            cliVersion: entry.cliVersion,
            model: entry.model,
            aiTitle: entry.aiTitle,
            firstPrompt: entry.firstPrompt,
            startedAt: entry.startedAt.map { Date(timeIntervalSince1970: $0) },
            lastActivityAt: Date(timeIntervalSince1970: entry.modified),
            fileSize: entry.fileSize
        )
        summary.userTurns = entry.humanTurns
        summary.assistantTurns = entry.assistantTurns
        summary.toolCalls = entry.toolCalls
        summary.contextTokens = entry.contextTokens
        summary.isSidechain = entry.isSidechain
        summary.isIndexed = true
        return summary
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
    }

    private func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

extension ISO8601DateFormatter {
    static let transcript: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Strips the harness preamble so a session card shows the human intent.
enum PromptCleaner {
    private static let wrappers = [
        ("<system_instruction>", "</system_instruction>"),
        ("<system-reminder>", "</system-reminder>"),
        ("<command-name>", "</command-name>"),
        ("<local-command-stdout>", "</local-command-stdout>"),
        ("<meshvy-brief>", "</meshvy-brief>")
    ]

    static func clean(_ raw: String) -> String {
        var text = raw
        for (open, close) in wrappers {
            while let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
            // Unclosed wrapper: drop everything from the opening tag onwards.
            if let start = text.range(of: open) {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
