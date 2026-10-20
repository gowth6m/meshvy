# Contributing to Meshvy

Thanks for looking. This is a macOS app for running several AI coding agents at
once on an infinite canvas, and the quickest way to be useful is to use it for
a day first — most of the good issues come from that rather than from reading
the code.

## Getting it running

You need macOS 14 or later and the Swift toolchain. **Xcode is optional** —
the Command Line Tools are enough to build and run:

```sh
git clone https://github.com/gowth6m/meshvy.git
cd meshvy
swift build              # ~35s cold, a few seconds after that
swift run Meshvy
```

For a real `.app` bundle (what the release ships):

```sh
./Scripts/build-app.sh   # UNIVERSAL=0 for a faster native-only build
open dist/Meshvy.app
```

Meshvy drives the `claude` CLI, so install [Claude
Code](https://claude.com/claude-code) before expecting an agent to start.

### Tests

```sh
swift test                              # everything
swift test --filter MeshvyCoreTests     # one module
```

One caveat: `swift test` needs **full Xcode** to actually run. The Command Line
Tools ship swift-testing's framework but not a working runner, so on a
CLT-only machine the suites compile and then execute nothing — silently, exit
code 0. `Package.swift` has a comment explaining the search paths involved. If
you are on CLT only, rely on CI for the unit suites and use the self-tests
below locally, since those are just the app.

### Self-tests

The app can exercise its own machinery. These have caught more regressions than
anything else, because they run the real thing:

```sh
BIN=dist/Meshvy.app/Contents/MacOS/Meshvy   # or .build/debug/Meshvy

$BIN --formattest            # decodes a board saved by an older version
$BIN --difftest .            # parses a real `git diff` (needs a dirty tree)
$BIN --canvastest            # the board's own handling (needs a workspace open)
$BIN --perftest              # loads your biggest transcript, times it
$BIN --launchtest            # boots far enough to compose a board
$BIN --hooktest              # drives the real `claude`, checks status hooks
$BIN --selftest <repo>...    # builds a workspace, runs agents, tears it down
```

The last two cost money, because they run actual agents. CI runs the first two;
the rest want a developer machine.

`--canvastest` is the one to reach for if you are on Command Line Tools only,
because it covers the same ground as `MeshvyCoreTests` and then keeps going
into the store, the `Workspace` model and `layout.json` — which is the half a
suite that never executes cannot tell you anything about. It needs a board, so
give it a throwaway one and a throwaway home to keep it in; every
`NSHomeDirectory()` lookup moves with the latter, so your own workspaces are
out of its reach:

```sh
SB="$PWD/.build/sandbox"
CFFIXED_USER_HOME="$SB" $BIN --selftest /path/to/repo --keep --name Scratch
CFFIXED_USER_HOME="$SB" $BIN --canvastest
```

Keep that sandbox under the git-ignored `.build/` rather than `/tmp`:
Foundation reports `/tmp/...` where git reports `/private/tmp/...`, so worktree
paths stop matching and every repository card shows a dash for its branch.

## How the code is laid out

```text
Apps/macOS/                  the app: entry point, menus, dev harnesses
Packages/
  Foundation/                pure values, no platform and no UI
    MeshvyCore/              camera, zoom thresholds, formatting, decoding
    MeshvyModels/            the vocabulary: Workspace, CanvasNode, sessions…
  Platform/                  one subsystem of the machine each
    ProcessKit/              running a subprocess
    FileSystemKit/           FSEvents, and scanning huge files by byte
    PersistenceKit/          what goes on disk
    GitKit/                  asking git about checkouts
    TerminalKit/             PTY-backed terminal sessions
  Features/                  capabilities, then the UI for them
    AgentKit/                driving a Claude Code session
    SessionKit/              reading Claude's own session files
    BrowserKit/              a page an agent can drive
    WorkspaceKit/            cutting worktrees for a workspace
    UpdateKit/               finding and installing a new Meshvy
    AgentsUI/ CanvasUI/ InspectorUI/ WorkspacesUI/
  DesignSystem/              theme, zoom, shared chrome
  AppState/                  the board, and everything the views read
  AppShell/                  window, sidebar, palette, status bar
Docs/
  architecture/              ADRs: why it is this way
  signing.md                 certificates and notarisation
  demo/                      repos the screenshot script builds on
Tools/                       architecture check, formatting
```

Every module has a `README.md` saying what it is for, what it depends on, and
how to test it. Start there.

### The one rule

**A module may depend only on lower tiers.**

```text
MeshvyCore
  └─ MeshvyModels
       └─ ProcessKit · FileSystemKit
            └─ PersistenceKit · GitKit · TerminalKit · DesignSystem
                 └─ AgentKit · SessionKit · BrowserKit · WorkspaceKit · UpdateKit
                      └─ AppState
                           └─ AgentsUI · CanvasUI · InspectorUI · WorkspacesUI
                                └─ AppShell
                                     └─ Meshvy
```

Plus two consequences worth stating on their own:

- **`AppState` depends on no UI module.** This is what lets the feature UIs be
  separate modules. If you find yourself adding a UI import to `AppState`, what
  you want is probably a value in `MeshvyCore` — that is why
  `BoardMetrics.sessionNode` lives there rather than in `Theme`.
- **Sibling features do not import each other.** Two features needing the same
  view means it belongs in `DesignSystem`; needing the same value means
  `MeshvyCore` or `MeshvyModels`. The exception on the books is
  `CanvasUI → AgentsUI`, because node cards show agent badges.

Checked in CI, and locally:

```sh
python3 Tools/check-architecture.py
```

SwiftPM already rejects an undeclared dependency and a cycle. What it has no
opinion about is *direction* — nothing in a manifest stops `AppShell` turning
up in `MeshvyCore`'s dependencies. That script is the part SwiftPM will not do
for you. Same-tier edges live in its `ALLOWED_PEERS`, each with a reason; if
you add one, add the reason.

### Where does my change go?

- **A new kind of node on the canvas** — the model in `MeshvyModels`, the view
  in `CanvasUI`, the state in `AppState`.
- **A new thing an agent can do** — `AgentKit`, and if it needs a tool
  definition, next to `BrowserBridge` as a model of how that is done.
- **A view two screens need** — `DesignSystem`.
- **Reading something off disk** — the raw reading in `FileSystemKit`, what it
  means in whichever capability kit owns the format.
- **A new module** — open an issue first. The bar is in
  [ADR 1](Docs/Architecture/0001-modular-monolith.md); roughly, a
  nameable owner, a public surface narrower than its internals, and a test
  suite that makes sense on its own. Then add it to `TIERS` in
  `Tools/check-architecture.py`, or the check will tell you to.

## Style

Follow the file you are in. Concretely:

- **4 spaces**, no tabs. Lines under ~120 columns.
- `swift format` is configured in `.swift-format` and runs via
  `./Tools/format.sh`. **The repository is not formatted yet** — the config
  matches the house style but the pretty-printer still wants ~1,500 lines of
  layout changes, including reindenting the embedded JavaScript in
  `BrowserScripts.swift`. That reformat is worth doing as its own reviewed
  commit; please do not fold it into a change that also moves code.
- One primary type per file, named after it. Extensions in `Type+Concern.swift`
  — see `MeshvyStore+Agents.swift`.
- `@Observable` for state, `async`/`await` and actors for concurrency. No new
  singletons; pass dependencies in. `Notifier.onReveal` is the pattern for a
  low-level service that needs to call back up.
- **Comments say why, not what.** This is the strongest convention in the
  codebase and the most useful thing to copy. `Zoom.typeScale` explains why
  type scales on a square root; `Shell.run` explains why git gets
  `GIT_TERMINAL_PROMPT=0`. A comment restating the code is worse than none.
- Public API on a module boundary gets a doc comment. Internal code gets one
  when the reason is not obvious.

## Pull requests

1. Branch off `main`.
2. `swift build` clean — **CI fails on any warning in `Packages/` or `Apps/`**.
3. `python3 Tools/check-architecture.py` clean.
4. `swift test` for what you touched, and a self-test if you touched the board,
   persistence, or the agent bridge.
5. Describe what changed and why. If you made a trade-off, say so — a note in
   the PR about what you decided against is worth more than a tidy diff.
6. Behaviour change to anything persisted? Say so explicitly. A board someone
   cannot open is the worst bug this app has.

Architectural changes want an ADR in `Docs/Architecture/`, in the
style of the existing ones: context, decision, what was rejected and why, and a
concrete trigger for revisiting it.

## Reporting things

- **Bug** — what you did, what happened, what you expected. macOS version, and
  whether the build is from a release or from source.
- **Crash** — the macOS crash report, if you can get it.
- **Security** — not an issue, please. See [SECURITY.md](SECURITY.md).
