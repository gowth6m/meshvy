import Foundation

/// Small JSON-file store under Application Support. Used for the layout and the
/// transcript index cache — both are regenerable, so read failures are silent.
struct FileStore<Value: Codable> {
    let url: URL

    init(filename: String) {
        url = FileStore.supportDirectory().appendingPathComponent(filename)
    }

    static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("Meshvy", isDirectory: true)

        // The app has been through a few names; carry state over rather than
        // silently starting empty for anyone who used an earlier one. Newest
        // first, so the most recent state wins if several exist.
        if !FileManager.default.fileExists(atPath: directory.path) {
            for former in ["Orkestr", "Arcforge", "Forge"] {
                let legacy = base.appendingPathComponent(former, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacy.path) {
                    try? FileManager.default.moveItem(at: legacy, to: directory)
                    break
                }
            }
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic replace so a crash mid-write cannot leave a truncated cache.
        try? data.write(to: url, options: .atomic)
    }
}

/// Decoding that tolerates a key that is not there.
///
/// Swift's synthesised `init(from:)` ignores a property's default value and
/// insists on the key being present. For a file the app rewrites on every
/// change that is fine — until a release adds a field, at which point every
/// board saved before it existed fails to decode and the user opens Meshvy to
/// find their workspaces gone. These let a model read an older file and fill in
/// what was not written yet.
extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is absent or unreadable.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    /// The stored value of an optional field, or nil.
    func optional<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// Node positions the user has dragged, plus the camera, so the board reopens
/// exactly as it was left.
struct SavedLayout: Codable {
    struct Point: Codable { var x: Double; var y: Double }

    var version: Int = 1
    var pinned: [String: Point] = [:]
    var cameraX: Double = 0
    var cameraY: Double = 0
    var scale: Double = 1
    var grouping: String = "link"
    var showEndedSessions: Bool = true
    var invertScroll: Bool = false
    var sidebarWidth: Double = 262
    var inspectorWidth: Double = 430
    var permissionMode: String = PermissionMode.acceptEdits.rawValue
    var notificationsEnabled: Bool = false
    // What the last agent was launched with, so the next one matches. Optional
    // so a layout saved before these existed still decodes.
    var effort: String?
    /// Nil is ambiguous for a model — it is also what "inherit the CLI default"
    /// means — so the choice is stored as a flag and a value.
    var hasModelChoice: Bool?
    var modelID: String?
}
