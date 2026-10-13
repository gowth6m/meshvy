import Foundation
import MeshvyModels
import Testing

@testable import PersistenceKit

@Suite("FileStore")
struct FileStoreTests {
    /// A store on a name nothing else uses, removed afterwards. `FileStore`
    /// always writes under Application Support, so there is no directory to
    /// inject — a unique filename is what keeps a test run off real state.
    private func scratch<T: Codable>(_: T.Type) -> (FileStore<T>, () -> Void) {
        let store = FileStore<T>(filename: "test-\(UUID().uuidString).json")
        return (store, { try? FileManager.default.removeItem(at: store.url) })
    }

    @Test("a saved value comes back")
    func roundTrip() {
        let (store, cleanup) = scratch(SavedLayout.self)
        defer { cleanup() }
        var layout = SavedLayout()
        layout.scale = 1.75
        layout.sidebarWidth = 300
        layout.pinned = ["s:abc": .init(x: 10, y: -20)]
        store.save(layout)

        let loaded = store.load()
        #expect(loaded?.scale == 1.75)
        #expect(loaded?.sidebarWidth == 300)
        #expect(loaded?.pinned["s:abc"]?.x == 10)
        #expect(loaded?.pinned["s:abc"]?.y == -20)
    }

    @Test("a store with no file yet loads as nil rather than throwing")
    func missingFile() {
        let (store, cleanup) = scratch(SavedLayout.self)
        defer { cleanup() }
        #expect(store.load() == nil)
    }

    // These files are regenerable, so a damaged one must not be fatal: the app
    // should come up with defaults rather than refuse to launch.
    @Test("unreadable contents load as nil instead of crashing")
    func corruptFile() throws {
        let (store, cleanup) = scratch(SavedLayout.self)
        defer { cleanup() }
        try Data("not json at all".utf8).write(to: store.url)
        #expect(store.load() == nil)
    }

    @Test("saving twice leaves the second value, not a mix of both")
    func overwrite() {
        let (store, cleanup) = scratch(SavedLayout.self)
        defer { cleanup() }
        var first = SavedLayout(); first.grouping = "link"
        var second = SavedLayout(); second.grouping = "repo"
        store.save(first)
        store.save(second)
        #expect(store.load()?.grouping == "repo")
    }

    @Test("the support directory exists once asked for")
    func supportDirectory() {
        let directory = FileStore<SavedLayout>.supportDirectory()
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(directory.lastPathComponent == "Meshvy")
    }
}

@Suite("SavedLayout")
struct SavedLayoutTests {
    @Test("a layout written by this version round trips through JSON")
    func roundTrip() throws {
        var layout = SavedLayout()
        layout.cameraX = 12.5
        layout.grouping = "repo"
        let data = try JSONEncoder().encode(layout)
        let back = try JSONDecoder().decode(SavedLayout.self, from: data)
        #expect(back.cameraX == 12.5)
        #expect(back.grouping == "repo")
    }

    @Test("the defaults are the ones the app opens with")
    func defaults() {
        let layout = SavedLayout()
        #expect(layout.version == 1)
        #expect(layout.scale == 1)
        #expect(layout.sidebarWidth == 262)
        #expect(layout.inspectorWidth == 430)
        #expect(layout.showEndedSessions)
        #expect(layout.permissionMode == PermissionMode.acceptEdits.rawValue)
    }

    // Unlike `Workspace`, this type takes Swift's synthesised `init(from:)`, so
    // every key has to be present however many defaults the properties carry.
    // A file from a build that predates a field therefore fails to decode and
    // `FileStore.load()` returns nil, which the app reads as "no saved layout"
    // and opens on the defaults above — the camera and the panel widths are
    // lost, but the board itself is not, because workspaces decode leniently.
    // Documented here rather than changed: making it lenient is a behaviour
    // change, not a refactor. See ADR 0004.
    @Test("a layout missing a key does not decode, and the app falls back")
    func missingKeyIsNotLenient() {
        let partial = Data(#"{"version":1,"cameraX":12.5}"#.utf8)
        #expect((try? JSONDecoder().decode(SavedLayout.self, from: partial)) == nil)
    }
}
