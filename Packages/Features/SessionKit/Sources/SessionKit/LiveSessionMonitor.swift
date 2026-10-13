import Darwin
import Foundation
import MeshvyModels

/// Reads `~/.claude/sessions/<pid>.json`, the registry the CLI maintains for
/// every running session. Gives us live `busy` / `idle` state, the session's
/// working directory and the name Conductor derived for it.
public struct LiveSessionMonitor {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public func snapshot() -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(parse)
            // Registry files outlive their process; drop the stale ones.
            .filter { isAlive($0.pid) }
    }

    private func parse(_ url: URL) -> LiveSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int,
              let sessionId = object["sessionId"] as? String
        else { return nil }

        let rawStatus = (object["status"] as? String)?.lowercased()
        let status: SessionStatus = rawStatus == "busy" ? .busy : .idle

        return LiveSession(
            pid: Int32(pid),
            sessionId: sessionId,
            cwd: object["cwd"] as? String,
            name: object["name"] as? String,
            version: object["version"] as? String,
            entrypoint: object["entrypoint"] as? String,
            kind: object["kind"] as? String,
            status: status,
            startedAt: epochMillis(object["startedAt"]),
            updatedAt: epochMillis(object["updatedAt"])
        )
    }

    private func epochMillis(_ value: Any?) -> Date? {
        guard let millis = value as? Double ?? (value as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// `kill(pid, 0)` probes existence without signalling. `EPERM` means the
    /// process exists but is owned by someone else, which still counts as alive.
    private func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
