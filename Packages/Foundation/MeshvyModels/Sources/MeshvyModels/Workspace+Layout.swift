import Foundation

/// Where Meshvy keeps a workspace's own plumbing.
///
/// These four paths are a convention, not behaviour, and three different
/// subsystems need them: the agent bridge writes requests, the hook helper
/// writes events, and the browser bridge writes its MCP manifest. They used to
/// live on `AgentBridge`, which made the browser depend on the agent bridge for
/// nothing but string concatenation — and since the agent command line in turn
/// advertises the browser's tools, that was a cycle. They belong to the
/// workspace that owns the directory.
extension Workspace {
    /// `<root>/.meshvy`
    public var meshvyDirectory: String { root + "/.meshvy" }

    /// Spawn and send requests dropped by the `meshvy` helper.
    public var requestsDirectory: String { meshvyDirectory + "/requests" }

    /// One file per agent the orchestrator has delegated to.
    public var agentsDirectory: String { meshvyDirectory + "/agents" }

    /// Helpers put on an agent's `PATH`.
    public var binDirectory: String { meshvyDirectory + "/bin" }
}
