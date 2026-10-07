# Forge

A native macOS app that lays your Claude Code sessions and git worktrees out on
an infinite canvas.

Forge reads what the Claude CLI already writes to disk — nothing is sent
anywhere, no account, no daemon. Sessions that are running right now show live
`working` / `waiting` status; sessions that ended months ago are still on the
board, grouped under the repository they belonged to.

![The board](docs/board.png)

## What's on the board

**Session cards** come from `~/.claude/projects/<project>/<session>.jsonl`:
title, working directory, branch, model, how many prompts you sent, how many
tool calls it made, context size at the last turn, and when it was last active.

**Worktree cards** come from `git worktree list`: branch, dirty and untracked
counts, divergence from upstream, and the tip commit. Sessions connect by a line
to the worktree they ran in.

**Repository groups** collect every worktree of one repo, keyed by its shared
git directory, so linked worktrees fold together instead of looking like
separate projects.

**Archived lanes** catch the common case where a workspace was deleted after its
branch landed. Those sessions are matched back to their repository by path shape
rather than being dumped in an undifferentiated pile.

## Using it

| | |
|---|---|
| Pan | drag empty canvas, or scroll |
| Zoom | ⌘-scroll, pinch, or ⌘+ / ⌘− |
| Fit to content | ⌘0 |
| Actual size | ⌘1 |
| Find | ⌘F — matches dim everything else; ⇧⌘F frames the hits |
| Open a card | double-click, or click to select and read it in the inspector |
| Rearrange | drag a card; its position is remembered |
| Refresh | ⌘R, or ⇧⌘R for git state only |

Right-click any card to resume the session in Terminal, open the folder in your
editor, or copy the path, branch or session id.

The board updates itself: a filesystem watcher on `~/.claude` picks up new turns
as agents work, live status is polled every few seconds, and git state refreshes
in the background.

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

The transcript store here is 145 files and about 400 MB; decoding that as JSON
takes tens of seconds, which would make launch useless.

Instead `SessionIndexer` memory-maps each file and scans it as bytes, matching
literal needles like `"type":"assistant"` per line and only decoding the two or
three lines whose contents it actually needs. A full cold index of 412 MB takes
roughly **0.35 s**. Results are cached in
`~/Library/Application Support/Forge/`, keyed by size and mtime; because
transcripts are append-only, a file that has grown is re-scanned from its last
complete record rather than from the start.

The canvas renders in screen space rather than applying `scaleEffect` to a
scaled layer, so text stays crisp at any zoom, and it drops to drawing plain
blocks in a single `Canvas` pass once cards are too small to read.

## Layout

```
Sources/Forge/
  App/        entry point, menu commands, offscreen snapshot mode
  Core/       canvas geometry, theme, persistence
  Model/      sessions, git, the canvas graph
  Services/   byte scanner, indexer, transcript loader, git, FSEvents
  Store/      app state and auto-layout
  UI/         canvas, cards, sidebar, inspector, transcript reader
```

### Development snapshots

`Forge --snapshot out.png [--zoom 0.8] [--width W] [--height H]` renders the
real view tree against your real data and writes a PNG, with no window. Useful
for reviewing UI changes from a terminal.

Note that `ImageRenderer` does not materialise `ScrollView` content or AppKit
text fields, so scrolling panels swap to a plain stack under the
`forgeSnapshotMode` environment flag, and the search field renders as a
placeholder block in snapshots only.

## What Forge does not do

It is a viewer. It never writes to a repository, and the only git commands it
runs are read-only (with `GIT_OPTIONAL_LOCKS=0`, so inspecting a tree never
contends with an agent working in it). Resuming a session shells out to
Terminal rather than embedding a PTY.
