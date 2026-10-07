# Forge

A native macOS app for running coding agents across several repositories at once,
laid out on an infinite canvas.

Forge starts empty. You add the repositories you work on together as a
**workspace**, cut a **stack** — the same branch checked out as a worktree in
every repo — and then put agents to work across all of it. Running agents appear
on the board live, and you can read any transcript without leaving the app.

![The board](docs/board.png)

## The model

**Workspace** — the set of repositories you treat as one project. Add local
clones with the folder picker, or paste a GitHub URL and Forge clones it for you.

**Stack** — one branch name, realised as a `git worktree` in every repo of the
workspace. A change that spans three services is one stack: three checkouts, one
branch, moving together. Removing the stack tears down every worktree (and the
branch, if you ask).

**Agent** — a real `claude` process started in a stack, with the sibling repos
granted through `--add-dir` so a single agent can change all of them. Launch it
as an *orchestrator*, and Forge briefs it to plan the work and dispatch teammates
with the Agent tool rather than doing everything itself; launch it as a *worker*
for one scoped task.

Forge does not host the agent. It starts the real CLI with a pre-assigned
session id, so a launched agent registers itself in `~/.claude/sessions` and
shows up on the board through exactly the same path as a session you started in
a terminal yourself. `claude agents --json` sees them too.

## What's on the board

**Session cards** come from `~/.claude/projects/<project>/<session>.jsonl`:
title, working directory, branch, model, how many prompts you sent, how many tool
calls it made, context size at the last turn, and when it was last active. A
pulsing dot means the agent is working right now.

**Worktree cards** come from `git worktree list`: branch, dirty and untracked
counts, divergence from upstream, and the tip commit. Sessions connect by a line
to the checkout they ran in.

**Sections** group the board either by stack (default) or by repository.

![Empty state](docs/empty.png)

## Using it

| | |
|---|---|
| New workspace | ⇧⌘N |
| New stack | ⌘N |
| Add repositories | ⇧⌘O |
| Launch agent | ⇧⌘L |
| Pan | drag empty canvas, or scroll |
| Zoom | ⌘-scroll, pinch, or ⌘+ / ⌘− |
| Fit to content | ⌘0 · Actual size ⌘1 |
| Find | ⌘F — matches dim everything else; ⇧⌘F frames the hits |
| Open a card | double-click, or click to select and read it in the inspector |
| Rearrange | drag a card; its position is remembered |
| Refresh | ⌘R |

Right-click any card to launch an agent there, resume the session in Terminal,
open the folder in your editor, or copy a path, branch or session id.

Scrolling follows the system "natural scrolling" preference. If you want the
opposite, **View → Invert Scroll Direction**.

The board keeps itself current: a filesystem watcher on `~/.claude` picks up new
turns as agents work, live status is polled every few seconds, and git state
refreshes in the background.

## Build

Requires macOS 14+ and a Swift 6 toolchain. **Xcode is not needed** — the Swift
compiler and the macOS SDK that ship with the Command Line Tools are enough:

```sh
xcode-select --install     # if you don't already have the tools
./scripts/build-app.sh     # -> dist/Forge.app
open dist/Forge.app
```

The script builds with SwiftPM, assembles the bundle, and ad-hoc signs it. For
day-to-day work `swift build` and `swift run` work as usual.

## How it stays fast

A transcript store of a few hundred megabytes takes tens of seconds to decode as
JSON, which would make launch useless.

Instead `SessionIndexer` memory-maps each file and scans it as bytes, matching
literal needles like `"type":"assistant"` per line and only decoding the two or
three lines whose contents it actually needs. A cold index of 412 MB across 145
files takes roughly **0.35 s**. Results are cached in
`~/Library/Application Support/Forge/`, keyed by size and mtime; because
transcripts are append-only, a file that has grown is re-scanned from its last
complete record rather than from the start.

The canvas renders in screen space rather than applying `scaleEffect` to a scaled
layer, so text stays crisp at any zoom, and it drops to drawing plain blocks in a
single `Canvas` pass once cards are too small to read.

## Layout

```
Sources/Forge/
  App/        entry point, menu commands, offscreen snapshot + test harnesses
  Core/       canvas geometry, theme, persistence
  Model/      workspaces and stacks, sessions, git, the canvas graph
  Services/   byte scanner, indexer, transcript loader, git, stacks,
              agent launcher, FSEvents
  Store/      app state, board composition, auto-layout
  UI/         canvas, cards, sidebar, inspector, transcript reader, sheets
```

### Development harnesses

```sh
Forge --snapshot out.png [--zoom 0.9] [--width W] [--height H]
Forge --selftest <repoA> <repoB> [--keep]   # create a workspace + stack, verify, tear down
Forge --launchtest                          # launch a real agent into the active workspace
```

`--snapshot` renders the real view tree against your real data and writes a PNG
with no window, which is how the screenshots above were made.

Note that `ImageRenderer` does not materialise `ScrollView` content, and renders
AppKit-backed controls (`TextField`, `Menu`) as a yellow placeholder block.
Scrolling panels swap to a plain stack under the `forgeSnapshotMode` environment
flag; the search field and workspace menu look wrong **in snapshots only**.

## What Forge does not do

It never pushes, merges or rewrites history. Inspection is read-only and runs
with `GIT_OPTIONAL_LOCKS=0`, so looking at a tree never contends with an agent
working in it. The only git commands that write are `worktree add` and
`worktree remove`, both of which you ask for explicitly. Closing a workspace
removes Forge's record of it and leaves every checkout on disk alone.
