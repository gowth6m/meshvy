# Orkestr

A native macOS app for running coding agents across several repositories at
once, on an infinite canvas.

Orkestr starts empty. You create a **workspace** by picking the repositories you
work on together; Orkestr cuts one branch across all of them and checks each one
out side by side under `~/.orkestr/<workspace>/`. That folder is the parent an
orchestrator works from — open a terminal at its root and every repository is
literally a subdirectory, so one agent can put a sub-agent on each of them.

![The board](docs/board.png)

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/gowth6m/orkestr/releases), open it, and drag
Orkestr to Applications.

Requires **macOS 14 or later**. The build is universal — Apple Silicon and
Intel.

Orkestr drives the `claude` CLI rather than talking to the API itself, so
install [Claude Code](https://claude.com/claude-code) first and sign in.

> **Unsigned builds.** Until the project has an Apple Developer ID, releases are
> not signed or notarised, and macOS will refuse to open the app the first time
> with *"Apple could not verify Orkestr is free of malware."* Either
> right-click the app and choose **Open**, or clear the quarantine flag:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Orkestr.app
> ```
>
> Once signing secrets are added to the repository the releases are notarised
> and this step goes away — see [Releasing](#releasing).

## The model

**Workspace** — one branch, checked out as a `git worktree` in every repository
you picked, all under one folder:

```
~/.orkestr/payments-revamp/
  api/      → repo "api"    on branch payments-revamp
  web/      → repo "web"    on branch payments-revamp
  worker/   → repo "worker" on branch payments-revamp
```

Creating it is one step: name it, pick the repositories, choose the base branch
to cut from. Make another workspace for another branch.

**The workspace node** — the parent on the canvas. It names the workspace and
its branch, lists the repositories that belong to it, and *hosts* Claude Code in
its body: press **Start orchestrator** and a real PTY opens there, running
`claude` at the workspace root. Its system prompt names every repository and
tells it to dispatch a sub-agent per repo with the Agent tool rather than doing
the work itself. Edges run down to each repository it owns.

**Sub-agent nodes** — every agent the orchestrator dispatches appears as its own
node, linked back to the parent, showing the task it was given, which agent type
it is, whether it is still running, and what it reported back. These are Agent
tool calls inside the orchestrator's session rather than separate processes, so
Orkestr reads them live out of its transcript.

**Repo terminals** — right-click a repository card for its own `claude` or a
plain shell, in that checkout alone.

**Changes** — select a repository to see every file it has touched against
HEAD, with a unified diff showing both line numbers. Untracked files render as
all-added. Select the workspace node instead and you get the same list across
every repository at once, which is what you want after an orchestrator run.

Orkestr does not host the agent. It starts the real CLI inside the PTY with a
pre-assigned session id, so the agent registers itself in `~/.claude/sessions`
and the board can match its transcript to the terminal it runs in.
`claude agents --json` sees them too.

## Using it

| | |
|---|---|
| New workspace | ⇧⌘N |
| Add repositories | ⇧⌘O |
| Start / focus orchestrator | ⇧⌘T |
| Shell | ⌘T |
| Pan | drag empty canvas, or scroll |
| Zoom | ⌘-scroll, pinch, or ⌘+ / ⌘− |
| Fit to content | ⌘0 · Actual size ⌘1 |
| Find | ⌘F — matches dim everything else; ⇧⌘F frames the hits |
| Refresh | ⌘R |

Side panels drag to resize from their inner edge, and the file list and diff
have their own divider. Widths persist.

Drag any node by its title bar; drag the corner grip to resize the workspace
node or a terminal. Click a sub-agent to read its full task and result. Terminals are not restored
after a quit — the process is gone, so the board starts clean.

Scrolling follows the system "natural scrolling" preference;
**View → Invert Scroll Direction** if you want the opposite.

### First run in a new workspace

Claude Code asks you to trust a folder it has not seen before, so the first
orchestrator you open in a workspace shows its trust prompt — press Enter.
Orkestr deliberately does not pre-answer this: it would mean writing to
`~/.claude.json`, which every running Claude Code instance also writes, and a
read-modify-write there could clobber their changes.

## Build

Requires macOS 14+ and a Swift 6 toolchain. **Xcode is not needed** — the Swift
compiler and macOS SDK from the Command Line Tools are enough:

```sh
xcode-select --install     # if you don't already have the tools
./scripts/build-app.sh     # -> dist/Orkestr.app
open dist/Orkestr.app
```

`build-app.sh` produces a universal binary by cross-compiling each slice and
`lipo`-ing them together — SwiftPM's own `--arch a --arch b` needs Xcode's
`xcbuild`, which the Command Line Tools do not ship. Set `UNIVERSAL=0` for a
faster native-only build while developing.

The only dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
for the terminal emulator. The app icon is generated, not checked in as art —
`./scripts/make-icon.sh` redraws `Resources/AppIcon.icns` from
`scripts/make-icon.swift`.

## Releasing

`VERSION` is the single source of truth. Write the notes in `CHANGELOG.md`
under a matching `## [x.y.z]` heading, then:

```sh
./scripts/release.sh 0.7.0
git push origin HEAD && git push origin v0.7.0
```

The tag triggers `.github/workflows/release.yml`, which builds a universal app
on a macOS runner, packages a DMG and a zip with checksums, and publishes a
GitHub Release. `scripts/release.sh` refuses to tag if the tree is dirty, the
tag exists, or the changelog has no section for the version.

To build artifacts locally without tagging: `./scripts/package-release.sh`.

### Signing and notarisation

Releases work without an Apple Developer ID — they are just unsigned, and the
install note above applies. To sign them, add these repository secrets:

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | base64 of a Developer ID Application `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password for that `.p12` |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_KEY` | base64 of an App Store Connect `.p8` key |
| `NOTARY_KEY_ID` | that key's id |
| `NOTARY_ISSUER` | issuer UUID |

The workflow detects them and skips signing cleanly when they are absent, so
nothing breaks before you have them.

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
Sources/Orkestr/
  App/        entry point, menus, snapshot + test harnesses
  Core/       canvas geometry, theme, persistence
  Model/      workspaces, terminals, sub-agents, sessions, git, diffs,
              the canvas graph
  Services/   byte scanner, indexer, transcript loader, sub-agent tracker,
              git, workspace builder, terminal registry, model catalog, FSEvents
  Store/      app state, board composition
  UI/         canvas, workspace node, cards, terminals, sub-agents,
              sidebar, inspector, diff viewer, transcript reader
```

### Development harnesses

```sh
Orkestr --snapshot out.png [--zoom 0.8] [--width W] [--height H]
Orkestr --selftest <repoA> <repoB> <repoC> [--keep]   # build a workspace, verify, tear down
Orkestr --launchtest                                  # open an orchestrator and wait for it to register
Orkestr --perftest                                    # time transcript loading on your largest session
Orkestr --difftest <worktree>                         # dump the change list and a parsed diff
```

`--snapshot` renders the real view tree against your real data with no window.
Note that `ImageRenderer` does not materialise `ScrollView` content and draws
AppKit-backed controls (`TextField`, `Menu`) as a yellow placeholder — scrolling
panels swap to a plain stack under the `forgeSnapshotMode` flag, and the search
field and workspace menu look wrong **in snapshots only**.

## What Orkestr does not do

It never pushes, merges or rewrites history. Inspection is read-only and runs
with `GIT_OPTIONAL_LOCKS=0`, so looking at a tree never contends with an agent
working in it. The only git commands that write are `worktree add` and
`worktree remove`, both of which you ask for explicitly. Closing a workspace
keeps its checkouts unless you choose to delete them.
