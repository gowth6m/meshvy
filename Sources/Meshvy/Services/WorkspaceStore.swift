import Foundation

/// Persists workspaces to Application Support. Small enough to rewrite whole on
/// every change; the file is the source of truth for what the board shows.
struct WorkspaceStore {
    private let file = FileStore<Document>(filename: "workspaces.json")

    struct Document: Codable {
        var version: Int = 1
        var workspaces: [Workspace] = []
        var activeWorkspaceID: UUID?
    }

    func load() -> Document {
        file.load() ?? Document()
    }

    func save(_ document: Document) {
        file.save(document)
    }
}
