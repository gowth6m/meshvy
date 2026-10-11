import CoreServices
import Foundation

/// Recursive FSEvents watcher. Used on `~/.claude/projects` (transcripts append
/// as agents work) and `~/.claude/sessions` (status flips between busy/idle).
/// Events are coalesced by FSEvents latency plus a debounce, since a single
/// agent turn produces a burst of writes.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "orkestr.fsevents")
    private let debounce: DispatchWorkItem? = nil
    private var pendingWork: DispatchWorkItem?
    private let interval: TimeInterval
    private let handler: () -> Void

    init(paths: [String], debounce interval: TimeInterval = 0.6, handler: @escaping () -> Void) {
        self.interval = interval
        self.handler = handler
        start(paths: paths)
    }

    private func start(paths: [String]) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.schedule()
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Collapses a burst of writes into one callback.
    private func schedule() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handler() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    deinit {
        pendingWork?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
