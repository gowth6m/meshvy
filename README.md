<img src="docs/mark.png" width="76" alt="">

# Meshvy

A native macOS app for running coding agents across several repositories at
once, on an infinite canvas.

Meshvy starts empty. You create a **workspace** by picking the repositories you
work on together; Meshvy cuts one branch across all of them and checks each one
out side by side under `~/.meshvy/<workspace>/`. That folder is the parent an
orchestrator works from — open a terminal at its root and every repository is
literally a subdirectory, so one agent can put a sub-agent on each of them.

![The board](docs/board.png)

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/gowth6m/meshvy/releases), open it, and drag
Meshvy to Applications.

Requires **macOS 14 or later**. The build is universal — Apple Silicon and
Intel.

Meshvy drives the `claude` CLI rather than talking to the API itself, so
install [Claude Code](https://claude.com/claude-code) first and sign in.

> **Unsigned builds.** Until the project has an Apple Developer ID, releases are
> not signed or notarised, and macOS will refuse to open the app the first time
> with *"Apple could not verify Meshvy is free of malware."* Either
> right-click the app and choose **Open**, or clear the quarantine flag:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Meshvy.app
> ```
>
> Once signing secrets are added to the repository the releases are notarised
> and this step goes away — see [Releasing](#releasing).

## The model

**Workspace** — one branch, checked out as a `git worktree` in every repository
you picked, all under one folder:

```
~/.meshvy/payments-revamp/
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

**Delegated agents** — when the orchestrator splits work up, each teammate is a
**real Claude Code session with its own terminal on the canvas**, which you can
read, interrupt and type into. Edges run from the workspace node to each one.

It works through a small helper, `meshvy`, that Meshvy puts on the
orchestrator's PATH:

```sh
meshvy spawn <repo> "<task>"   # start an agent there; prints an agent id
meshvy wait <id>               # block until it finishes, print what it reported
meshvy send <id> "<message>"   # type a follow-up into its terminal
meshvy context <id>            # read what it has been doing, without interrupting
meshvy status                  # every agent on the board and what it is doing
meshvy list                    # agents on the board
```

`context` and `status` are pull, not push: nothing is forced into anyone's
context window. An orchestrator uses them to decide something before a worker
has finished, instead of blocking on `wait`.

The orchestrator is told to delegate this way rather than with Claude's Agent
tool. Agent-tool sub-agents run *inside* the parent process — no pid, no pty —
so there is nothing for a terminal to attach to and you cannot watch or steer
them. If one does get used anyway, it still shows up as a card read from the
parent's transcript, so no work is invisible.

The helper talks to Meshvy through files under `<workspace>/.meshvy/`, so it
keeps working across an app restart and needs nothing but a shell.

**Agent status** — every session Meshvy starts is handed a settings file whose
hooks call a small `meshvy-hook` script, so what a node reports comes from the
agent itself rather than from reading its screen. Four states — working,
waiting, blocked, done — collapse into the two words worth putting on a header:
a pulsing **RUNNING**, or **NEEDS YOU** when the agent is stopped on something
only you can answer. Under the header, a strip names the tool in flight and
what it is pointed at, the permission being asked for, or the first line of what
the agent said when it finished.

Because the hooks are given only to sessions Meshvy launches, they do nothing in
your own terminals, and `--settings` is an *additional* source — your own hooks
in `~/.claude/settings.json` keep firing alongside them.

The one dialog no hook can report is the one Claude Code shows *before* a
session exists: the trust prompt for a folder it has not seen, or the offer to
carry on when a settings file will not parse. An agent stopped on one would look
like it was thinking, so those two — and only those — are read off the screen.

**Unread and notifications** — an agent that finishes or gets stuck while you
are looking elsewhere is marked unread: a dot on its header and in the sidebar,
and a count on the Dock icon. Turn on **Agents → Notify Me When An Agent Needs
Me** and you also get an OS notification; clicking it focuses the window and
centres the node. Nothing is posted until you ask for it. ⌥⌘N walks through the
agents waiting on you.

**Permission modes** — new agents start in the mode you pick in the toolbar:
ask every time, auto, accept edits, plan first, or bypass. It is the *starting*
mode only — ⇧⇥ still cycles it inside a running session, exactly as it does in
Claude Code on its own.

**⌘K** — one box for starting an agent in any repository, switching workspace,
jumping to a node by name, branch or path, and changing the permission mode. It
also searches inside your terminals: type three characters or more and it
matches each live terminal's screen and shows the line it found, which is the
one thing the canvas cannot tell you — which of a dozen terminals printed the
error you half-remember.

**Repo terminals** — right-click a repository card for its own `claude` or a
plain shell, in that checkout alone.

**Changes** — select a repository to see every file it has touched against
HEAD, with a unified diff showing both line numbers. Untracked files render as
all-added. Select the workspace node instead and you get the same list across
every repository at once, which is what you want after an orchestrator run.

Meshvy does not host the agent. It starts the real CLI inside the PTY with a
pre-assigned session id, so the agent registers itself in `~/.claude/sessions`
and the board can match its transcript to the terminal it runs in.
`claude agents --json` sees them too.

## Using it

| | |
|---|---|
| Command palette | ⌘K |
| Keyboard shortcuts | ⌘/ |
| New workspace | ⇧⌘N |
| Add repositories | ⇧⌘O |
| Start / focus orchestrator | ⇧⌘T |
| Shell | ⌘T |
| Next agent waiting on you | ⌥⌘N |
| Pan | drag empty canvas, or scroll |
| Zoom | ⌘-scroll, pinch, or ⌘+ / ⌘− |
| Fit to content | ⌘0 · Actual size ⌘1 |
| Find | ⌘F — matches dim everything else; ⇧⌘F frames the hits |
| Refresh | ⌘R |
| Scroll a terminal | rest the pointer on it for half a second |

Side panels drag to resize from their inner edge, and the file list and diff
have their own divider. Widths persist.

Drag any node by its title bar; drag the corner grip to resize the workspace
node or a terminal. Click a sub-agent to read its full task and result. Terminals are not restored
after a quit — the process is gone, so the board starts clean.

Scrolling follows the system "natural scrolling" preference;
**View → Invert Scroll Direction** if you want the opposite.

The wheel pans the canvas, so a terminal's scrollback would be unreachable. Rest
the pointer on a terminal for half a second and it takes the wheel until the
pointer leaves — long enough that flicking across the board never scrolls one by
accident. The node says *hold to scroll* while you wait. Zoom stays the
canvas's, dwell or no dwell.

### First run in a new workspace

Claude Code asks you to trust a folder it has not seen before, so the first
orchestrator you open in a workspace shows its trust prompt — press Enter.
Meshvy deliberately does not pre-answer this: it would mean writing to
`~/.claude.json`, which every running Claude Code instance also writes, and a
read-modify-write there could clobber their changes.

What it does instead is say so. An agent sitting on that prompt — or on the one
Claude Code shows when `~/.claude/settings.json` will not parse — reads
**NEEDS YOU** on the board rather than looking like it is thinking.

## Build

Requires macOS 14+ and a Swift 6 toolchain. **Xcode is not needed** — the Swift
compiler and macOS SDK from the Command Line Tools are enough:

```sh
xcode-select --install     # if you don't already have the tools
./scripts/build-app.sh     # -> dist/Meshvy.app
open dist/Meshvy.app
```

`build-app.sh` produces a universal binary by cross-compiling each slice and
`lipo`-ing them together — SwiftPM's own `--arch a --arch b` needs Xcode's
`xcbuild`, which the Command Line Tools do not ship. Set `UNIVERSAL=0` for a
faster native-only build while developing.

The only dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
for the terminal emulator.

Brand assets live in `Resources/brand/`. `./scripts/make-icon.sh` rebuilds
`Resources/AppIcon.icns` from `app-icon.png`, scaling it to 824 of a 1024
canvas so it sits at the same size as every other icon in the Dock. The mark in
the toolbar is drawn in SwiftUI (`UI/BrandMark.swift`) from the same geometry as
`mark-on-dark.svg`, so it stays crisp and takes its colours from the theme.

## Updating

Meshvy checks GitHub Releases on launch. When a newer version exists a pill
appears in the toolbar; clicking it shows the release notes and
**Install and restart**, which downloads the zip, checks it against the
published SHA-256, swaps the bundle and reopens. There is also
**Meshvy → Check for Updates…**.

The repository is private, so both the release listing and the asset download
need a token. Meshvy asks the `gh` CLI you are already signed in to
(`gh auth token`), or uses `GITHUB_TOKEN` if it is set. Make the repository
public and it works with no token at all — the same code path.

Development builds (`swift run`, or a bundle stamped `0.0.0`) never offer
updates.

A running bundle cannot replace itself, so a detached helper waits for Meshvy
to quit, swaps the two, clears the quarantine flag and relaunches. If the swap
fails it puts the old bundle back, so a failed update never leaves you with
nothing installed.

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

Geometry and type zoom on different curves. Scaled linearly, a title is 5pt at
45% and shouts at 160%, so cards keep scaling with the canvas while type follows
`sqrt(zoom)` clamped to 0.8–1.3. Terminals magnify instead: the container's
coordinate system is scaled and the terminal's own frame is left alone, so the
grid never reflows and a running program is not forced to redraw on every zoom
step.

## Layout

```
Sources/Meshvy/
  App/        entry point, menus, snapshot + test harnesses
  Core/       canvas geometry, theme, persistence
  Model/      workspaces, terminals, sub-agents, sessions, git, diffs,
              the canvas graph
  Services/   byte scanner, indexer, transcript loader, sub-agent tracker,
              agent hooks, notifier, git, workspace builder, terminal registry,
              model catalog, FSEvents
  Store/      app state, board composition
  UI/         canvas, workspace node, cards, terminals, sub-agents,
              agent status, command palette, sidebar, inspector, diff viewer,
              transcript reader
```

### Development harnesses

```sh
Meshvy --snapshot out.png [--zoom 0.8] [--width W] [--height H]
                          [--palette | --shortcuts] [--agent]
Meshvy --selftest <repoA> <repoB> <repoC> [--keep]   # build a workspace, verify, tear down
Meshvy --launchtest                                  # orchestrator, fan-out, and what the hooks reported
Meshvy --hooktest [--keep]                           # run a real agent against the installed hooks
Meshvy --perftest                                    # time transcript loading on your largest session
Meshvy --difftest <worktree>                         # dump the change list and a parsed diff
```

`--hooktest` is the one that cannot be checked by looking at the board: it
installs the hooks into a throwaway workspace, runs a real `claude` through
them, and prints the states that came back.

`--snapshot` renders the real view tree against your real data with no window.
`--agent` starts an orchestrator first, so the status chrome has something to
show.
Note that `ImageRenderer` does not materialise `ScrollView` content and draws
AppKit-backed controls (`TextField`, `Menu`) as a yellow placeholder — scrolling
panels swap to a plain stack under the `forgeSnapshotMode` flag, and the search
field and workspace menu look wrong **in snapshots only**.

## What Meshvy does not do

It never pushes, merges or rewrites history. Inspection is read-only and runs
with `GIT_OPTIONAL_LOCKS=0`, so looking at a tree never contends with an agent
working in it. The only git commands that write are `worktree add` and
`worktree remove`, both of which you ask for explicitly. Closing a workspace
keeps its checkouts unless you choose to delete them.

## Licence

Source-available, not open source — see [LICENSE](LICENSE). You may run Meshvy
and fork or modify it for your own use, including at work. You may not
redistribute it or a derivative, or offer it to others as a service.
Gowtham Ravindrathas retains ownership; contributions are assigned to him.

The terminal emulator, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
is MIT-licensed by its own authors.
