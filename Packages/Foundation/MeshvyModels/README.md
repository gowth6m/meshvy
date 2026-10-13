# MeshvyModels

**The vocabulary the whole app speaks.**

`Workspace`, `WorkspaceRepo`, `TerminalNode`, `BrowserNode`, `CanvasNode`/`CanvasGraph`/`NodeID`, sessions and transcripts, diffs, git checkouts, agent activity, sub-agents.

Values and their own decoding, no behaviour. The persisted types hand-write `init(from:)` so a file written by an older build still loads — see [ADR 4](../../../Docs/Architecture/0004-forward-compatible-persistence.md).

## Depends on

- `MeshvyCore`

## Files

- `AgentActivity.swift`
- `BrowserNode.swift`
- `ClaudeSession.swift`
- `Diff.swift`
- `GitModels.swift`
- `GraphNode.swift`
- `SubAgent.swift`
- `Workspace+Layout.swift`
- `Workspace.swift`

9 files, 1463 lines.

## Tests

`swift test --filter MeshvyModelsTests`
