import Foundation
import MeshvyModels

/// Small JSON-file store under Application Support. Used for the layout and the
/// transcript index cache — both are regenerable, so read failures are silent.
public struct FileStore<Value: Codable> {
    public let url: URL

    public init(filename: String) {
        url = FileStore.supportDirectory().appendingPathComponent(filename)
    }

    public static func supportDirectory() -> URL {
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

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic replace so a crash mid-write cannot leave a truncated cache.
        try? data.write(to: url, options: .atomic)
    }
}

/// Node positions the user has dragged, plus the camera, so the board reopens
/// exactly as it was left.
public struct SavedLayout: Codable {
    public struct Point: Codable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var version: Int = 1
    public var pinned: [String: Point] = [:]
    public var cameraX: Double = 0
    public var cameraY: Double = 0
    public var scale: Double = 1
    public var grouping: String = "link"
    public var showEndedSessions: Bool = true
    public var invertScroll: Bool = false
    public var sidebarWidth: Double = 262
    public var inspectorWidth: Double = 430
    public var permissionMode: String = PermissionMode.acceptEdits.rawValue
    public var notificationsEnabled: Bool = false
    // What the last agent was launched with, so the next one matches. Optional
    // so a layout saved before these existed still decodes.
    public var effort: String?
    /// Nil is ambiguous for a model — it is also what "inherit the CLI default"
    /// means — so the choice is stored as a flag and a value.
    public var hasModelChoice: Bool?
    public var modelID: String?

    public init(
        version: Int = 1,
        pinned: [String: Point] = [:],
        cameraX: Double = 0,
        cameraY: Double = 0,
        scale: Double = 1,
        grouping: String = "link",
        showEndedSessions: Bool = true,
        invertScroll: Bool = false,
        sidebarWidth: Double = 262,
        inspectorWidth: Double = 430,
        permissionMode: String = PermissionMode.acceptEdits.rawValue,
        notificationsEnabled: Bool = false,
        effort: String? = nil,
        hasModelChoice: Bool? = nil,
        modelID: String? = nil
    ) {
        self.version = version
        self.pinned = pinned
        self.cameraX = cameraX
        self.cameraY = cameraY
        self.scale = scale
        self.grouping = grouping
        self.showEndedSessions = showEndedSessions
        self.invertScroll = invertScroll
        self.sidebarWidth = sidebarWidth
        self.inspectorWidth = inspectorWidth
        self.permissionMode = permissionMode
        self.notificationsEnabled = notificationsEnabled
        self.effort = effort
        self.hasModelChoice = hasModelChoice
        self.modelID = modelID
    }
}
