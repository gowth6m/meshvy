import Foundation
import Testing

@testable import MeshvyModels

@Suite("NodeID")
struct NodeIDTests {
    // Node ids key the saved layout, so a storage key that stopped round
    // tripping would silently scatter everyone's board on the next launch.
    @Test("every case survives a trip through its storage key")
    func roundTrip() throws {
        let uuid = UUID()
        let cases: [NodeID] = [
            .session("abc-123"), .worktree("/tmp/repo"), .terminal(uuid),
            .workspace(uuid), .subAgent("tool-7"), .browser(uuid),
        ]
        for id in cases {
            #expect(NodeID(storageKey: id.storageKey) == id, "\(id) did not round trip")
        }
    }

    @Test("each case has its own prefix, so keys cannot collide")
    func prefixesAreDistinct() {
        let uuid = UUID()
        let keys: [NodeID] = [
            .session("x"), .worktree("x"), .terminal(uuid),
            .workspace(uuid), .subAgent("x"), .browser(uuid),
        ]
        let prefixes = Set(keys.map { $0.storageKey.prefix(2) })
        #expect(prefixes.count == keys.count)
    }

    @Test("a key we do not recognise is rejected", arguments: [
        "", "z:nope", "nocolon", "t:not-a-uuid", "k:not-a-uuid", "b:not-a-uuid",
    ])
    func rejectsGarbage(key: String) {
        #expect(NodeID(storageKey: key) == nil)
    }

    @Test("a path containing a colon still round trips")
    func pathWithColon() {
        let id = NodeID.worktree("/tmp/a:b/repo")
        #expect(NodeID(storageKey: id.storageKey) == id)
    }
}

@Suite("Workspace")
struct WorkspaceTests {
    @Test("names become branch-safe slugs", arguments: [
        ("Payments revamp", "payments-revamp"),
        ("  spaced  out  ", "spaced-out"),
        ("Foo/Bar:Baz", "foo-bar-baz"),
        ("MiXeD CaSe", "mixed-case"),
        ("kebab-already", "kebab-already"),
        ("v2.1 release", "v2-1-release"),
    ])
    func slug(name: String, expected: String) {
        #expect(Workspace.slug(name) == expected)
    }

    @Test("a name with nothing usable in it still yields a branch name")
    func slugFallback() {
        #expect(Workspace.slug("") == "workspace")
        #expect(Workspace.slug("///") == "workspace")
    }

    // These four paths are a convention three subsystems share; if they drift
    // apart the agent bridge and the browser bridge stop finding each other.
    @Test("the workspace's own directories hang off its root")
    func layoutPaths() {
        let workspace = Workspace(name: "Demo", branch: "demo", root: "/tmp/ws")
        #expect(workspace.meshvyDirectory == "/tmp/ws/.meshvy")
        #expect(workspace.requestsDirectory == "/tmp/ws/.meshvy/requests")
        #expect(workspace.agentsDirectory == "/tmp/ws/.meshvy/agents")
        #expect(workspace.binDirectory == "/tmp/ws/.meshvy/bin")
    }
}
