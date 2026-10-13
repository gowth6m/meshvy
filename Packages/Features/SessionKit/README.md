# SessionKit

**Reading Claude's own session files.**

`SessionIndexer` (the transcript index, cached and incremental), `TranscriptLoader`, `LiveSessionMonitor` (the CLI's registry of running sessions), and `PromptCleaner`, which strips the machine-generated wrappers off a first user message so a card shows what the person typed.

## Depends on

- `FileSystemKit`
- `MeshvyCore`
- `MeshvyModels`
- `PersistenceKit`

## Files

- `LiveSessionMonitor.swift`
- `SessionIndexer.swift`
- `TranscriptLoader.swift`

3 files, 721 lines.

## Tests

`swift test --filter SessionKitTests`
