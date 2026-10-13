# 4. Saved files must decode leniently — and one of them does not

Accepted · 2026-10-13

## Context

Meshvy writes two kinds of state to disk:

- **the board** — `Workspace` and friends, in `workspaces.json`
- **the layout** — `SavedLayout`: camera, panel widths, pinned node positions,
  grouping, permission mode

`Workspace`, `WorkspaceRepo`, `TerminalNode` and `BrowserNode` each hand-write
`init(from:)` using `container.value(_:or:)`, so a key that is not in the file
falls back to the property's default. The comment on that helper explains why:
Swift's synthesised `init(from:)` ignores default values and insists on the key
being present, so without it a release that adds a field makes every board
saved before it undecodable, and the user opens Meshvy to find their workspaces
gone. `--formattest` covers exactly this, against a fixture missing the
`browsers` field.

Writing tests for `PersistenceKit` turned up that **`SavedLayout` does not do
this.** It takes the synthesised `init(from:)`, so every key is required
however many defaults its properties carry.

## What actually happens today

A layout file written before a field was added fails to decode.
`FileStore.load()` is `try? JSONDecoder().decode(...)`, so the failure is
silent and returns nil, and the app reads nil as "no saved layout" and opens on
defaults.

So the blast radius is bounded: you lose your camera position, panel widths,
pinned nodes and grouping — not your workspaces, because those decode
leniently. It degrades rather than breaking, which is presumably why it has
never been noticed.

## Decision

**Documented, not fixed, in this change.** Making `SavedLayout` lenient means
hand-writing its `init(from:)`, which is a behaviour change to persistence, and
this change is a refactor — the two should not land together, because if a
board comes back wrong afterwards nobody can tell which half did it.

`PersistenceKitTests` asserts the real behaviour, with the reasoning, so the
gap is visible to the next person rather than being folded away.

## Next step, concretely

Give `SavedLayout` the same `init(from:)` treatment as `Workspace`, and extend
`--formattest` with a layout fixture that is missing a field, the way it
already has a board fixture missing one. Then the rule "everything we persist
decodes leniently" is covered rather than merely intended.
