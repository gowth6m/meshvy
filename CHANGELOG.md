# Changelog

## [Unreleased]

- **Install and uninstall in one command.** `scripts/install.sh` fetches the
  latest release, verifies its checksum, installs to `/Applications` and clears
  the quarantine flag; run it again to update.
- `scripts/uninstall.sh` removes the app, its settings, the keychain entry and
  the workspaces — and ships inside the bundle, reachable from
  **Meshvy → Uninstall Meshvy…**, so someone who installed from a DMG has it
  without a checkout. Workspaces under `~/.meshvy` are git worktrees registered
  in real repositories, so each is handed back with `git worktree remove` and
  the origin pruned rather than deleted; a checkout holding uncommitted or
  unpushed work is kept and reported unless `--force`. It also declines to
  remove the root while it holds a workspace Meshvy has no record of, and
  leaves a development build in a checkout alone.

- Documentation rewritten around what the app actually does now, with fresh
  screenshots of the board, the changes panel, the command palette and the
  empty state.
- Snapshots render honestly. `ImageRenderer` cannot draw an embedded terminal
  or an AppKit control, so a documentation shot used to show a blank card and
  yellow blocks where the search field and menus are. Terminals now draw their
  real screen buffer as text, and each control has a static twin, both behind
  the `meshvySnapshotMode` flag — the live app is untouched.
- `--snapshot --orchestrator "<task>"` starts an agent, answers Claude Code's
  first-run prompts and waits for a reply before rendering, so the hero shot
  shows a real exchange rather than an empty terminal.

## [0.8.0] - 2026-10-11

- **In-app updates.** Meshvy checks GitHub Releases on launch, shows a pill in
  the toolbar when there is a newer version, and installs it on request:
  download, SHA-256 check against the published list, bundle validation, then a
  detached helper swaps the app and relaunches it. It restores the old bundle
  if the swap fails. The repository is private, so the token comes from the
  `gh` CLI you are already signed in to; a public repository needs none.
  Development builds never offer updates.
- **Delegated agents are real terminals.** The orchestrator used Claude's Agent
  tool, whose sub-agents run inside the parent process with no pid and no pty —
  nothing a terminal could attach to, so the board could only draw them as
  cards. Delegation now goes through a `meshvy` helper on the agent's PATH
  (`spawn`, `wait`, `send`, `list`), and every agent it starts is a real Claude
  Code session with its own terminal node, linked back to the workspace.
- `Bash(meshvy:*)` is pre-approved, since `acceptEdits` does not cover Bash and
  an orchestrator that stops to ask permission for every spawn never gets going.
- **Type and geometry zoom on different curves.** Scaled linearly, card text was
  mush at 45% and shouted at 160%. Cards still scale with the canvas; type
  follows `sqrt(zoom)` clamped to 0.8–1.3, with the padding around text on the
  same curve so pills keep their proportions.
- **Terminals magnify instead of reflowing.** Their glyphs were a fixed 11.5pt
  at every zoom — the one thing on the board that ignored the zoom control.
  Scaling the container's coordinate system and leaving the terminal's frame
  alone means the text scales while the grid stays put, so a running program is
  not redrawn on each zoom step.
- One store per process; the scene and the headless harnesses were each making
  their own, racing for the same agent-bridge requests.

**Agents say what they are doing.**

- Every session Meshvy starts is handed a settings file whose hooks call a tiny
  `meshvy-hook` script, so status comes from the agent itself rather than from
  reading its screen. Four states — working, waiting, blocked, done — collapse
  into the two words that matter on a header: a pulsing **RUNNING**, or
  **NEEDS YOU** when something is stopped on a question only you can answer.
- A node that has an agent in it carries a status strip under its header: the
  tool in flight and what it is pointed at (`Edit  Sources/Theme.swift`), the
  permission being asked for, or the first line of what the agent said when it
  finished. The strip is always there — one that appeared and vanished with each
  tool call would resize the terminal under it, and SwiftTerm reflows its whole
  grid on a resize.
- An agent that changes state while you are looking elsewhere is marked unread:
  a dot on its header and in the sidebar, a count on the Dock icon, and — if you
  turn notifications on — a notification that focuses the window and centres the
  node when clicked. Nothing is posted until you ask for it.
- The one dialog no hook can report is the one Claude Code shows *before* a
  session exists: the trust prompt for a folder it has not seen, or the offer to
  carry on when `settings.json` will not parse. An agent stopped on one used to
  look like it was thinking. Those two are read off the screen, narrowly, and
  only while a session has never reported.
- `⌥⌘N` walks you through the agents waiting on you; the count in the toolbar
  does the same with the mouse.
- The sidebar's "Running" list is now **Agents** — orchestrator included,
  ordered by how much each one wants your attention, with its live line
  underneath.

**⌘K.**

- One box for starting an agent in any repository, switching workspace, jumping
  to any node by name, branch or path, and changing the permission mode.
- It also searches *inside* your terminals: with three characters or more it
  matches each live terminal's screen and shows the line it found, which is the
  one thing the canvas cannot tell you — which of a dozen terminals printed the
  error you half-remember.
- `⌘/` lists the keys, including the gestures a canvas cannot advertise.

**Permission modes.** New agents launch in a mode you pick — ask every time,
auto, accept edits, plan, or bypass — from the toolbar, the Agents menu or the
palette. It sets the starting mode only; ⇧⇥ still cycles it inside a running
session.

**The wheel stops fighting the terminals.** Scrolling panned the canvas
everywhere, which meant a terminal's scrollback was unreachable. Resting the
pointer on one for half a second hands it the wheel until the pointer leaves,
and the node says so while you wait. Zoom stays the canvas's.

**Agents can read each other.** The helper gains `meshvy context <id>`, which
prints what another agent has been doing without interrupting it, and
`meshvy status`, which lists every agent on the board and its current state —
pull, not push, so nothing is forced into anyone's context.

- `Meshvy --hooktest` runs a real `claude` against the installed hooks and
  checks what comes back. `--snapshot` gains `--palette`, `--shortcuts` and
  `--agent` so the chrome that only exists on a keystroke can be captured.

The board is **Night Owl**.

- `Theme` now holds the thirteen Night Owl values and derives everything else
  from them: the surface ramp (`#001122` chrome → `#011627` canvas → three card
  fills blended toward `#1D3B53`), the text ramp down to `#637777`, hairlines
  and hover fills, which are tinted with the palette's panel colour instead of
  white. No view hardcodes a colour any more.
- Blue `#82AAFF` carries selection and primary actions. Because every Night Owl
  accent is pastel, anything filled with it puts the background back on top
  (`Theme.onAccent`) to stay readable.
- Status: busy amber `#ECC48D`, idle teal, clean green, dirty orange, branches
  purple, sidechains pink. Failures split out of "dirty" into their own red
  `#FF6363` — a failed tool call, an unusable repository and a deleted line are
  red; a checkout with uncommitted work stays orange.
- Terminals are themed too: background, foreground, caret, selection and the
  sixteen ANSI slots, so what an agent prints on the canvas is Night Owl as
  well. Bright variants are lifted 22% toward the foreground.
- Repository tints are drawn from the palette's seven accents rather than the
  whole hue wheel, and system controls follow the accent instead of the user's
  macOS one.
- The mark keeps its shape and takes the palette's purple `#C792EA`; the
  shipped icon assets are unchanged.

The top bar is one row.

- The window's hidden title bar no longer leaves a 32pt strip above the bar
  with the traffic lights marooned in it: the bar runs to the top of the
  window and the lights are nudged onto its centre line, so every control in
  the chrome sits on one line. They are put back after the relayouts (resize,
  key changes, full screen) that reset them.
- The sidebar toggle moves left to sit just past the lights, and the inspector
  toggle ends the bar, so the two panel toggles read as its ends. Zoom and
  refresh group with the inspector toggle behind a divider, mirroring the
  sidebar toggle's. In full screen, where there are no lights, the bar takes
  their gutter back.
- The toggle stays in place, dimmed, when there is no workspace open, so the
  mark and workspace menu do not shift sideways when one opens.

## [0.7.0] - 2026-10-11

Renamed to **Meshvy**, with the brand applied.

- App, bundle (`dev.gowtham.meshvy`), binary, target and support directory are
  all Meshvy. State from any former name is migrated on first launch; new
  workspaces live under `~/.meshvy/`.
- The supplied app icon replaces the generated one, scaled onto Apple's grid
  so it matches other Dock icons rather than sitting oversized.
- The mark is drawn in SwiftUI from the SVG's own geometry, so it is crisp at
  any size and themed rather than bitmapped.
- Brand palette: purple `#6E56F8` takes over selection, primary actions and the
  structural edges between a workspace and its repositories; text moves to the
  mark's cream `#F3F3EE`; surfaces shift toward the icon's navy. Status colours
  stay independent — an agent at work is still amber, clean is still teal —
  and repository cards move to a neutral slate so purple stays the brand's.

## [0.6.1] - 2026-10-11

- Fixed a sub-agent whose dispatch carried neither a description nor a prompt
  being titled with an empty string. CI caught the dead `??` behind it — the
  local toolchain did not warn, the runner's did.

## [0.6.0] - 2026-10-11

Renamed to **Meshvy**, and set up for release.

- The app, bundle (`dev.gowtham.meshvy`), binary and support directory are
  all Meshvy now. State written under either former name is migrated on
  first launch rather than silently ignored. New workspaces live under
  `~/.meshvy/`; existing ones keep the root they were created with, since
  git stores absolute paths in its worktree registrations.
- A generated app icon, drawn by `scripts/make-icon.swift` rather than checked
  in as art.
- Universal builds. SwiftPM's `--arch` needs Xcode's `xcbuild`, which the
  Command Line Tools lack, so each slice is cross-compiled and `lipo`-ed.
- `scripts/package-release.sh` produces a DMG, a zip and SHA-256 checksums,
  signing and notarising when Apple credentials are present and saying so when
  they are not.
- `.github/workflows/release.yml` builds and publishes on a `v*` tag;
  `ci.yml` builds every push and fails on compiler warnings.

## [0.5.1] - 2026-10-11

A place to read code changes, resizable panels, and less chrome.

- **Diff viewer.** Selecting a repository lists every file it has touched
  against HEAD — modified, added, deleted, renamed and untracked — with per-file
  +/− counts and a unified diff showing both old and new line numbers.
  Untracked files are rendered as all-added. Selecting the workspace node shows
  the same list across every repository at once.
- **Resizable panels.** Both side panels drag from their inner edge, and the
  file list and diff have their own divider. Widths persist between launches.
- **Less chrome.** Dropped the Shell and Ended buttons from the toolbar (both
  still available from context menus and the View menu), replaced the canvas
  hint text in the status bar with a changed-file count, and cut the field grid
  from the repository panel down to a single state line.

## [0.5.0] - 2026-10-11

The workspace is now a node you can open, and sub-agents show up on the board.

- **The workspace node hosts Claude Code.** The workspace used to be a
  translucent background container with the orchestrator floating separately.
  It is now the parent node itself: it names the branch, lists the repositories
  that belong to it, and opens a real Claude Code PTY in its body. Edges run
  down to each repository.
- **Sub-agent nodes.** Every agent the orchestrator dispatches with the Agent
  tool appears as its own node linked back to the parent, with its task, agent
  type, running state, token count and result. Agent-tool sub-agents never
  register in `~/.claude/sessions` — they live inside the parent's transcript —
  so Forge tails that transcript and surfaces them from there.
- Verified end to end: an orchestrator asked to fan out across three repos
  produced three sub-agent nodes, each with its own result.

## [0.4.0] - 2026-10-07

Simplified to one concept, and terminals now live on the canvas.

- **A workspace is the worktrees.** Creating one is a single step: name it, pick
  repositories, choose a base branch. Forge cuts that branch in every repo and
  checks each out under `~/.forge/<workspace>/`. The separate "linked worktree"
  layer is gone — a workspace *is* the linked set.
- **Terminal nodes.** Real PTYs on the canvas, via SwiftTerm. An orchestrator
  runs `claude` at the workspace root with every repository as a subdirectory
  beneath it, briefed to dispatch a sub-agent per repo with the Agent tool; an
  agent terminal runs inside one checkout; a shell is just a shell. Drag by the
  title bar, resize from the corner.
- **The sidebar lists every workspace** with its repositories nested underneath,
  not just the open one.
- Terminals are owned by a registry rather than by the view, so panning and
  zooming no longer restarts the shell. They are not restored after a quit.

## [0.3.0] - 2026-10-07

Workspace-first, and a much faster inspector.

- **The workspace is the organising unit.** What was a "stack" is now a *linked
  worktree*: one branch checked out in every repo of the workspace. The board
  leads with the workspace and its linked worktrees; grouping by repository is
  still there as the second option.
- **Workspace-scoped agents.** An agent can now own the whole workspace — every
  repository and every linked worktree granted through `--add-dir` — not just
  one checkout. Verified across three repos.
- **Opening a session is ~4x faster.** The transcript reader decoded the entire
  file to show the most recent events; a 76 MB session took 265 ms before the
  panel could draw. It now decodes the last 24 MB and takes 62 ms whatever the
  length. Side panels also open without an animation (one relayout instead of
  one per frame), cards carry a shadow only when selected or hovered, and the
  canvas no longer renders through an extra offscreen pass.
- **Models come from the API.** A current built-in list (Opus 5 by default,
  Fable 5.1, Opus 4.8, Sonnet 5, Haiku 4.5) replaces the stale hardcoded one,
  and `GET /v1/models` supplies the live list when an API key is saved in the
  keychain. The key is only used for listing; agents use the CLI's own sign-in.
- Top bar reorganised around a single primary action, with grouping as a
  segmented control and zoom as one cluster.

## [0.2.0] - 2026-10-07

Forge is now a workspace manager, not just a viewer.

- **Workspaces.** The app starts empty. Add the repositories you work on
  together — from disk, or by pasting a GitHub URL to clone.
- **Stacks.** Cut one branch as a `git worktree` across every repo in the
  workspace at once; remove it the same way.
- **Agents.** Launch a real `claude` session into a stack, with sibling repos
  granted via `--add-dir`. Orchestrators are briefed to dispatch teammates with
  the Agent tool. Launched agents appear on the board automatically.
- Board groups by stack (default) or by repository.
- Fixed scroll direction: `isDirectionInvertedFromDevice` was being used to
  negate deltas AppKit had already adjusted, which inverted trackpad panning.
  Added **View → Invert Scroll Direction** for anyone who wants the opposite.
- Model labels read `Haiku 4.5` rather than `Haiku 4 5`.
- Forge's own brief to an agent no longer leaks into the session card's title.

## [0.1.0] - 2026-10-07

First release.

- Infinite canvas of Claude Code sessions and git worktrees, grouped by repository.
- Live status for running sessions, read from the CLI's own session registry.
- Incremental transcript index so a 400 MB history opens in well under a second.
- Transcript reader with tool-call, thinking and system filters.
- Git state per worktree: branch, dirty counts, upstream divergence, tip commit.
- Drag to arrange, search to filter, layout persisted between launches.
