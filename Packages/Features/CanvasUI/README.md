# CanvasUI

**The infinite canvas and the cards on it.**

`CanvasView` and its backdrop, plus a view per node kind: workspace, terminal, browser, session, sub-agent. `TerminalSurface` hosts a live PTY view here.

Nodes are drawn in screen space rather than with `.scaleEffect`, so text stays crisp at any zoom; `Zoom` and `DetailLevel` are what make that work.

## Depends on

- `AgentKit`
- `AgentsUI`
- `AppState`
- `BrowserKit`
- `DesignSystem`
- `MeshvyModels`
- `TerminalKit`

## Files

- `BrowserNodeView.swift`
- `CanvasBackdrop.swift`
- `CanvasView.swift`
- `SessionNodeView.swift`
- `SubAgentNodeView.swift`
- `TerminalNodeView.swift`
- `TerminalSurface.swift`
- `WorkspaceNodeView.swift`

8 files, 2015 lines.

## Tests

No suite yet. Worth adding one for anything here that is a pure function of its inputs.
