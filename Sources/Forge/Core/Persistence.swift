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
        let directory = base.appendingPathComponent("Forge", isDirectory: true)
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
}
