# AgentKit

**Driving a Claude Code session.**

The `claude` command line (`AgentCommand`), the on-disk protocol the coordinator uses to start threads and hear back from them (`AgentBridge`), the status hooks (`AgentHooks`), sub-agent tracking, the model catalog, and notifications.

`Notifier` takes an `onReveal` callback rather than reaching for the store — see [ADR 2](../../../Docs/Architecture/0002-appstate-bottleneck.md).

## Depends on

- `BrowserKit`
- `FileSystemKit`
- `MeshvyCore`
- `MeshvyModels`
- `ProcessKit`

## Files

- `AgentBridge.swift`
- `AgentCommand.swift`
- `AgentHooks.swift`
- `ModelCatalog.swift`
- `Notifier.swift`
- `SubAgentTracker.swift`

6 files, 1266 lines.

## Tests

`swift test --filter AgentKitTests`
