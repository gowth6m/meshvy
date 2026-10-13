# PersistenceKit

**Where state goes on disk.**

`FileStore` (a small JSON file under Application Support), `SavedLayout` (camera, panel widths, pinned positions) and `WorkspaceStore` (the board).

Both files are regenerable, so read failures are silent and the app falls back to defaults.

## Depends on

- `MeshvyCore`
- `MeshvyModels`

## Files

- `Persistence.swift`
- `WorkspaceStore.swift`

2 files, 147 lines.

## Tests

`swift test --filter PersistenceKitTests`
