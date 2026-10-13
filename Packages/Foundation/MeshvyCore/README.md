# MeshvyCore

**Pure values with no dependencies of their own.**

The canvas camera (`Viewport`), how much detail a node draws at a given zoom (`DetailLevel`), board dimensions (`BoardMetrics`), human-readable formatting (`Format`), the transcript timestamp format, and the lenient-decoding helper every persisted model uses.

Nothing here knows about workspaces, agents, the filesystem or SwiftUI. If a type needs any of those, it belongs one tier up.

## Depends on

Nothing — it is the bottom of the graph.

## Files

- `BoardMetrics.swift`
- `Decoding.swift`
- `Format.swift`
- `Geometry.swift`
- `Timestamps.swift`

5 files, 243 lines.

## Tests

`swift test --filter MeshvyCoreTests`
