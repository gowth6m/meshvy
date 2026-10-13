# 2. AppState is a known bottleneck, and the next thing to split

Accepted · 2026-10-13

## Context

`MeshvyStore` is the board: workspaces, selection, viewport, the agent bridge,
hook-driven status, browsers, sub-agents, git, diffs, transcripts, the camera.
Before this refactor it was one 1,930-line `@Observable` class read by 17 of the
app's 61 files.

Every feature UI needs it. That makes it the one module the whole top half of
the graph depends on, which is the opposite of what "independent features" is
supposed to mean.

## Decision

Keep it one type, in its own module, and split the **file** along the seams it
already had.

`MeshvyStore.swift` is now 11 files: the stored state and its collaborators,
plus one extension per concern (`+Workspaces`, `+Agents`, `+Browsers`,
`+SubAgents`, `+Sessions`, `+Git`, `+Graph`, `+Camera`, `+Shell`,
`+Lifecycle`). The split is along the `// MARK:` boundaries that were already
in the file, so no logic moved and no behaviour changed.

Critically, **`AppState` depends on no UI module**. That one edge is what lets
`CanvasUI`, `InspectorUI`, `AgentsUI` and `WorkspacesUI` be separate modules at
all: they depend on `AppState`, and `AppState` does not depend back.

## Why not per-feature stores now

That is the right end state — `CanvasStore`, `AgentsStore`, `WorkspacesStore`,
each owned by the people who own the matching UI. It is not this change,
because the interesting parts of the store are **coupled through state, not
through code**:

- a hook event updates `activity`, which changes a node's badge, which the
  canvas re-reads
- `rebuild()` recomposes the whole graph from workspaces + sessions + git +
  sub-agents, so every concern feeds one derived value
- `reveal(_:)` moves the camera in response to something an agent did

Splitting those into separate observable objects means inventing the
coordination that the single store currently gets for free from being one
object. Done carelessly it produces stale badges and a canvas that does not
redraw — bugs that are invisible in review and obvious to a user. It needs its
own change, with the harnesses (`--selftest`, `--hooktest`) run against it.

## Consequences

- Ownership works today: `CODEOWNERS` can name `MeshvyStore+Agents.swift`
  separately from `MeshvyStore+Git.swift`.
- `private` members of the store became `internal`, because a cross-file
  extension cannot see them. The module boundary carries that guarantee now:
  nothing outside `AppState` can reach them regardless. Members the UI reads
  are `public internal(set)` — readable by a feature, writable only in here.
- The bottleneck is real and is not hidden by this change. **Trigger to act:**
  when two features need to change the store for unrelated reasons in the same
  week, or when `MeshvyStore+<X>.swift` passes ~600 lines, split that concern
  into its own observable object.

## Next step, concretely

`+Browsers` (325 lines) is the best first candidate: browser nodes are the
least entangled concern, it talks to `BrowserKit` and almost nothing else, and
`BrowserNodeView` is already the only reader of most of it.
