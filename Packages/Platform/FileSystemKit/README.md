# FileSystemKit

**Watching the filesystem, and reading very large files cheaply.**

`DirectoryWatcher` (FSEvents, coalesced) and the byte scanner — `JSONLScanner`, `LineView`, `StaticNeedle` — that walks newline-delimited transcripts without decoding them.

The scanner exists because the transcript store reaches hundreds of megabytes and `JSONSerialization` over it takes tens of seconds; a byte scan takes well under one.

## Depends on

Nothing — it is the bottom of the graph.

## Files

- `ByteScan.swift`
- `DirectoryWatcher.swift`

2 files, 245 lines.

## Tests

`swift test --filter FileSystemKitTests`
