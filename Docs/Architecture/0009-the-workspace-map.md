# 9. The workspace map

Accepted · 2026-11-22

## Context

Meshvy's main job is changing from orchestrating agents to showing how an app
across several repositories fits together, drawn by AI. Floorplan
(gowth6m/floorplan, MIT) already does that as a Claude Code skill: zero-
dependency Node scripts do the mechanical part (scan, match requests to
endpoints, lay out the map), Claude names and describes what it finds, and the
result is a self-contained HTML map with its own small local server for the
Ask bar.

## Decision

**Bundle the engine, do not port it.** `Engine/Floorplan` is Floorplan's skill
folder and test suite, nearly unchanged (`MESHVY.md` lists the changes), and
`build-app.sh` copies the skill into the app. Rewriting fifteen thousand lines
of tested scanners in Swift would buy nothing a user can see, and keeping the
copy close to upstream keeps upgrades a file copy.

**Claude runs headless.** `MapRun` starts `claude -p` at the workspace root,
points it at the bundled `SKILL.md`, and reads its `stream-json` output into
one line of progress for the workspace node. It may read the code, write the
map's files, and run only the engine's own scripts; anything else is refused,
since nobody is there to be asked.

**The map is a web page on the board.** `Floorplan.serve` starts the engine's
server through its own `open.mjs` and a browser node shows it. Drawing the map
natively on the canvas, from `graph.json`, is the next step and does not need
this one undone.

**Node is required, not shipped.** Meshvy looks for it and says plainly when it
is missing. Shipping a Node runtime would add ~100 MB to a 10 MB app.

## Consequences

- A map needs Node 18+ and a signed-in Claude Code.
- The engine's tests run in CI (`npm test` in `Engine/Floorplan`).
- The map lives in `floorplan/` in the workspace folder, outside every
  repository, so it is never committed by accident.
