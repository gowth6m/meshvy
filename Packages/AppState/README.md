# AppState

**The board, and everything the views read.**

`MeshvyStore` — one `@Observable` type split across files by concern — and `BoardComposer`, which derives the canvas graph from workspaces, sessions, git and sub-agents.

**Depends on no UI module.** That is the edge that lets the feature UIs be separate modules at all. It is also the app's one real bottleneck; [ADR 2](../../Docs/Architecture/0002-appstate-bottleneck.md) says why it is still one type and what splits next.

## Depends on

- `AgentKit`
- `BrowserKit`
- `FileSystemKit`
- `GitKit`
- `MeshvyCore`
- `MeshvyModels`
- `PersistenceKit`
- `ProcessKit`
- `SessionKit`
- `TerminalKit`
- `UpdateKit`
- `WorkspaceKit`

## Files

- `BoardComposer.swift`
- `MeshvyStore+Agents.swift`
- `MeshvyStore+Browsers.swift`
- `MeshvyStore+Camera.swift`
- `MeshvyStore+Git.swift`
- `MeshvyStore+Graph.swift`
- `MeshvyStore+Lifecycle.swift`
- `MeshvyStore+Sessions.swift`
- `MeshvyStore+Shell.swift`
- `MeshvyStore+SubAgents.swift`
- `MeshvyStore+Workspaces.swift`
- `MeshvyStore.swift`

12 files, 2256 lines.

## Tests

No suite yet. Worth adding one for anything here that is a pure function of its inputs.
