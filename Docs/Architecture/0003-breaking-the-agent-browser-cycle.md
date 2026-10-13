# 3. Per-workspace paths belong to the workspace

Accepted · 2026-10-13

## Context

Drawing the module boundaries surfaced a circular dependency that the single
target had hidden:

- `AgentCommand` (AgentKit) read `BrowserBridge.toolPrefix` and
  `BrowserBridge.brief`, to tell a new agent what browser tools it has.
- `BrowserBridge` (BrowserKit) read `AgentBridge.directory(for:)` and
  `AgentBridge.binDirectory(for:)`, to find where to write its MCP manifest.

AgentKit → BrowserKit → AgentKit. In one target this was invisible; as two
modules it does not build.

## Decision

The four path helpers were never about the agent bridge. `directory(for:)` was
`workspace.root + "/.meshvy"` — a convention about where Meshvy keeps a
workspace's plumbing, which three subsystems share: the agent bridge writes
requests, the hook helper writes events, the browser bridge writes its manifest.

They moved onto `Workspace` itself, in `MeshvyModels`:

```swift
workspace.meshvyDirectory    // <root>/.meshvy
workspace.requestsDirectory  // .../requests
workspace.agentsDirectory    // .../agents
workspace.binDirectory       // .../bin
```

The remaining edge, AgentKit → BrowserKit, is one-directional and meaningful:
an agent's command line advertises the browser's tools.

## Consequences

- The directory layout now has one owner — the type that owns the directory.
- Both halves of the convention are covered by tests
  (`MeshvyModelsTests`, `AgentKitTests`), which they were not before.
- A third bridge needing these paths adds no dependency on the first two.
