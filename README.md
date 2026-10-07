# Forge

A native macOS app for running coding agents across several repositories at
once, on an infinite canvas.

Forge starts empty. You create a **workspace** by picking the repositories you
work on together; Forge cuts one branch across all of them and checks each one
out side by side under `~/.forge/<workspace>/`. That folder is the parent an
orchestrator works from — open a terminal at its root and every repository is
literally a subdirectory, so one agent can put a sub-agent on each of them.

![The board](docs/board.png)

## The model

**Workspace** — one branch, checked out as a `git worktree` in every repository
you picked, all under one folder:

```
~/.forge/payments-revamp/
  api/      → repo "api"    on branch payments-revamp
  web/      → repo "web"    on branch payments-revamp
  worker/   → repo "worker" on branch payments-revamp
```

Creating it is one step: name it, pick the repositories, choose the base branch
to cut from. Make another workspace for another branch.

**Terminal** — a real PTY on the canvas, not a link to Terminal.app. Three kinds:

- **Orchestrator** — runs `claude` at the workspace root. Its system prompt
  names every repository and tells it to dispatch a sub-agent per repo with the
  Agent tool rather than doing the work itself. Draws an edge to every
  repository it owns.
- **Agent** — runs `claude` inside one repository's checkout.
- **Shell** — a plain login shell.

Forge does not host the agent. It starts the real CLI inside the PTY with a
pre-assigned session id, so the agent registers itself in `~/.claude/sessions`
and the board can match its transcript to the terminal it runs in.
`claude agents --json` sees them too.

## Using it

| | |
|---|---|
| New workspace | ⇧⌘N |
| Add repositories | ⇧⌘O |
| Orchestrator terminal | ⇧⌘T |
| Shell | ⌘T |
| Pan | drag empty canvas, or scroll |
| Zoom | ⌘-scroll, pinch, or ⌘+ / ⌘− |
| Fit to content | ⌘0 · Actual size ⌘1 |
| Find | ⌘F — matches dim everything else; ⇧⌘F frames the hits |
| Refresh | ⌘R |

Drag a terminal by its title bar; drag the corner grip to resize. Right-click a
repository card to open an agent or a shell in it. Terminals are not restored
after a quit — the process is gone, so the board starts clean.

Scrolling follows the system "natural scrolling" preference;
**View → Invert Scroll Direction** if you want the opposite.

### First run in a new workspace

Claude Code asks you to trust a folder it has not seen before, so the first
orchestrator you open in a workspace shows its trust prompt — press Enter.
Forge deliberately does not pre-answer this: it would mean writing to
`~/.claude.json`, which every running Claude Code instance also writes, and a
read-modify-write there could clobber their changes.

## Build

Requires macOS 14+ and a Swift 6 toolchain. **Xcode is not needed** — the Swift
compiler and macOS SDK from the Command Line Tools are enough:

```sh
xcode-select --install     # if you don't already have the tools
./scripts/build-app.sh     # -> dist/Forge.app
open dist/Forge.app
```

The only dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
for the terminal emulator.

## How it stays fast

Opening a session decodes only the tail of its transcript — 24 MB, back from
the end. Most transcripts are smaller and are read whole; the pathological ones
(tens of megabytes of tool output) took **265 ms** to decode in full before the
panel could draw, and now take **62 ms** whatever the length.

Session metadata comes from a byte scan rather than a JSON decode: the indexer
memory-maps each transcript and matches literal needles like `"type":"assistant"`
per line, decoding only the few lines whose contents it needs. A cold index of
412 MB across 145 files takes about **0.35 s**, cached by size and mtime, and a
file that has grown is re-scanned from its last complete record.

Terminals are owned by `TerminalRegistry`, not by the SwiftUI view that shows
them — SwiftUI rebuilds node views on every pan and zoom, and creating the
emulator in `makeNSView` would kill and restart the shell each time.

The canvas renders in screen space rather than scaling a rendered layer, so text
stays crisp at any zoom, and drops to plain blocks in a single `Canvas` pass once
cards are too small to read.

## Layout

```
Sources/Forge/
  App/        entry point, menus, snapshot + test harnesses
  Core/       canvas geometry, theme, persistence
  Model/      workspaces, terminals, sessions, git, the canvas graph
  Services/   byte scanner, indexer, transcript loader, git,
              workspace builder, terminal registry, model catalog, FSEvents
  Store/      app state, board composition
  UI/         canvas, cards, terminals, sidebar, inspector, transcript reader
```

### Development harnesses

```sh
Forge --snapshot out.png [--zoom 0.8] [--width W] [--height H]
Forge --selftest <repoA> <repoB> <repoC> [--keep]   # build a workspace, verify, tear down
Forge --launchtest                                  # open an orchestrator and wait for it to register
Forge --perftest                                    # time transcript loading on your largest session
```

`--snapshot` renders the real view tree against your real data with no window.
Note that `ImageRenderer` does not materialise `ScrollView` content and draws
AppKit-backed controls (`TextField`, `Menu`) as a yellow placeholder — scrolling
panels swap to a plain stack under the `forgeSnapshotMode` flag, and the search
field and workspace menu look wrong **in snapshots only**.

## What Forge does not do

It never pushes, merges or rewrites history. Inspection is read-only and runs
with `GIT_OPTIONAL_LOCKS=0`, so looking at a tree never contends with an agent
working in it. The only git commands that write are `worktree add` and
`worktree remove`, both of which you ask for explicitly. Closing a workspace
keeps its checkouts unless you choose to delete them.
