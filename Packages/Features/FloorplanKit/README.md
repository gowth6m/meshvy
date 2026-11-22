# FloorplanKit

**The workspace map.**

`Floorplan` finds the map engine bundled with the app (`Engine/Floorplan` in
this repository, `Contents/Resources/floorplan` in the app) and the `node` to
run it with, writes the opening message for the thread that draws or refreshes
a map, and starts the map's local server so a browser node can show it.

Claude does the reading and describing, in an ordinary thread on the board.
Nothing here calls a model.

## Depends on

- `ProcessKit`

## Files

- `Floorplan.swift`

## Tests

`FloorplanKitTests`: parsing `open.mjs` output and Node versions, where Node
and the engine are looked for, the permission rules and the map task.
