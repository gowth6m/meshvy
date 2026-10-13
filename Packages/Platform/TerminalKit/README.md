# TerminalKit

**PTY-backed terminal sessions.**

`TerminalRegistry` owns the live `TerminalSession`s and the SwiftTerm views they draw into; the registry outlives any particular node so a session survives a board rebuild.

`TerminalSurface`, the view that puts a session on the canvas, is in `CanvasUI` — a view here would put SwiftUI underneath the application state.

## Depends on

- `MeshvyModels`
- `SwiftTerm`

## Files

- `TerminalRegistry.swift`

1 file, 191 lines.

## Tests

No suite yet. Worth adding one for anything here that is a pure function of its inputs.
