import Foundation
import MeshvyModels

/// Persists workspaces to Application Support. Small enough to rewrite whole on
/// every change; the file is the source of truth for what the board shows.
public struct WorkspaceStore {
    public init() {}

    private let file = FileStore<Document>(filename: "workspaces.json")

    public struct Document: Codable {
        public var version: Int = 1
        public var workspaces: [Workspace] = []
        public var activeWorkspaceID: UUID?

        public init(
            version: Int = 1,
            workspaces: [Workspace] = [],
            activeWorkspaceID: UUID? = nil
        ) {
            self.version = version
            self.workspaces = workspaces
            self.activeWorkspaceID = activeWorkspaceID
        }
    }

    public func load() -> Document {
        file.load() ?? Document()
    }

    public func save(_ document: Document) {
        file.save(document)
    }
}
