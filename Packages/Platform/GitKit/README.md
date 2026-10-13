# GitKit

**Asking git about checkouts.**

`GitService`: discovering repositories from candidate paths and folding every linked worktree of one repository into a single `Repo`, reading branch/ahead/behind/dirty state, and producing the diffs the inspector shows.

All calls are read-only and run off the main thread.

## Depends on

- `MeshvyModels`
- `ProcessKit`

## Files

- `GitService.swift`

1 file, 207 lines.

## Tests

`swift test --filter GitKitTests`
