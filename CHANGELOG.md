# Changelog

## [0.11.0] - 2026-10-13

- **Repositories are no longer nodes on the board.** Every workspace hung a
  small card per repository beneath its node, wired to it — a second copy of
  the chips the node already carries, under a branch name the whole workspace
  shares. The board is for what runs in them: agents, sessions and browsers.
  A repository lives on its chip now. Click it for the changes and the diff,
  exactly as the card did; right-click it to open an agent, a shell or a
  browser there, or to open it in your editor. The sidebar row does the same,
  and brings the workspace node into view.
- Past sessions still sit in a row beneath the workspace node, a column per
  repository that has any, and their edges run to the workspace itself — as do
  a browser's and an agent's you opened by hand. Every edge on the board now
  has the workspace node at one end.

## [0.10.5] - 2026-10-13

- **Nothing could be dragged above the workspace node, and which nodes would
  move at all depended on where they were sitting.** A terminal, browser or
  workspace node is moved by its chrome, so its body keeps text selection —
  but the test for "is this the chrome?" was re-asked on every step of the
  drag, against the node's *current* top. That top falls as the node is
  dragged upwards, so a node on its way up eventually failed a test it had
  already passed and stopped dead, part of the way there. The test is settled
  once now, when the drag begins.
- The same comparison measured a drag's start in the gesture's local space
  against an edge in the board's, so whether a node could be picked up at all
  came down to where it happened to be: a node low on the board could be
  dragged by its whole body, and one whose top had scrolled above the canvas
  could not be dragged anywhere. The board's coordinate space is named now,
  and both sides of the comparison are taken in it.
- The grab area matches each kind's actual chrome. Every kind was given the
  28pt of a terminal's header, which left most of a workspace node's 78pt of
  header and repository strip, and most of a browser's address bar, looking
  draggable and not being. Both the drag and the scroll wheel read the same
  measurement now, so they cannot disagree about where a card's own surface
  begins.
- Workspace and browser nodes no longer have an invisible second copy of
  themselves laid on top. The card layer skipped only terminals, so it also
  drew an empty, node-sized view over every workspace and browser — carrying
  a drag with no chrome test, two tap gestures and a context menu, all
  competing for the same clicks as the real node underneath.
- **"The request timed out" when installing an update.** The downloader read
  the asset one byte at a time out of `URLSession.AsyncBytes`, appending each
  to a `Data` — about 140 KB/s on an idle machine, so a five-megabyte update
  the network had already delivered in under a second took 38 seconds to
  collect, against a 30-second timeout. Worse, every member of `UpdateService`
  is on the main actor, so that loop ran on the main thread, behind the canvas
  and every terminal redrawing on it: the connection sat waiting to be read
  until the request gave up. It streams straight to a file now, off the main
  thread, which is 1.7 seconds for the same asset. The transfer also has a
  budget of its own — `timeoutInterval` on a request is the gap between
  packets, which never said anything about how long the whole download may
  take.
- The progress bar moves while an update downloads. It was fed by counting
  bytes through the loop above; the replacement reports from the session's own
  delegate, which has to belong to the session rather than the task — a
  task-level delegate is never sent `didWriteData` on Darwin, and the bar
  would have sat at nothing until it jumped to done.
- Checking for updates no longer blocks the main thread. `gh auth token` was
  shelled out to, synchronously with an eight-second timeout, on the main
  actor, for every request the updater made.

## [0.10.4] - 2026-10-13

- **An orchestrator that exited left its workspace node with nothing to press.**
  The node chose between the terminal and the start prompt on whether a session
  existed, not on whether it was still running — and a session whose process
  ends on its own (`/exit`, Ctrl-D, a crash) stays in the registry, so the last
  screen of an agent remains readable. The board had meanwhile collapsed the
  node to its idle height and the header had dropped its stop button, so what
  was left was a blank panel: no terminal to read and no way to start another
  agent from the node. It shows the start prompt again as soon as the process
  ends.
- **The board no longer pans behind the ⌘K palette.** The canvas takes the
  scroll wheel through an app-wide event monitor gated on a hover flag, and
  that flag only changes when the pointer moves — so a palette opened from the
  keyboard, over a pointer that then stayed where it was, scrolled the board
  underneath it and swallowed the wheel the palette's own result list wanted.
  Anything drawn over the board — the palette, the shortcut list, a sheet —
  now keeps the wheel while it is up.
- **Installing no longer needs the `gh` CLI.** The repository is public, so the
  one-liner fetches the script with `curl` and there is nothing to sign in to.
  `install.sh` already preferred `gh` only when it was there; the README and the
  script's own header said the opposite of what is now true, and now do not.
- **New brand artwork, and mint `#64FFDA` as the primary colour.** The icon and
  the mark were still drawn in the old brand purple `#6E56F8` on cream, which
  had nothing to do with the Night Owl board behind them. Both are redrawn in
  the theme's own colours — `#011627` ground, `#D6DEEB` mark — with mint on the
  lit node, and mint takes over from Night Owl's blue as the accent: selection,
  primary actions, and the edges between a workspace and its repositories. The
  toolbar mark now matches the shipped artwork exactly instead of substituting
  purple for the lit node. Status colours stay independent, as before. There is
  a new `app-icon-mint` variant, the inverse of the shipped icon.
- **New screenshots, of the build that actually ships.** The old ones predated
  the browser, the agent settings on every card and archiving, and showed a
  board of two repositories with nothing running on it. The hero is now a real
  delegated run: three repositories on one branch, an agent in flight in two of
  them, the orchestrator waiting on both, and the app they are changing open on
  the board beside them. There is a new shot of a browser node and its console,
  and the rest have been retaken.
- `scripts/make-shots.sh` builds the board the images are taken against instead
  of using whatever happens to be on the author's machine — three throwaway
  repositories from `docs/demo/`, a workspace cut across them, a dev server,
  and an orchestrator run that delegates. It puts the worktrees, the scratch
  repositories and your own board back afterwards. The shots are reproducible,
  and a public README no longer depends on private work being open.
- **A browser draws its real page in a documentation shot.** `ImageRenderer`
  cannot draw a `WKWebView` at all, so every shot with a browser in it showed a
  grey globe. The session now captures a still — in an offscreen window, since
  a view with no window snapshots to nothing — and the snapshot twin draws
  that, the same trick the terminals already use for their screen buffer.
- `--snapshot` waits on the agent's own hooks rather than on the word "esc to
  interrupt" being on screen. The CLI rotates that hint, so a shot timed on it
  landed on half-written answers. It also refreshes git before rendering and
  waits for the read to finish, so the repository cards are not caught empty,
  and it frames and selects what the shot is actually about: `--select
  workspace|browser|repo`, and `--zoom` now centres on the selection rather
  than always on the workspace node.
- `--snapshot --browser` and `--snapshot --orchestrator` can be used together.
  The browser was opened after the orchestrator branch had already returned, so
  asking for both silently gave you neither.
- A diff in a documentation shot had its left-hand gutter cut off, line numbers
  and all. The stand-in for a `ScrollView` was given `.top` alignment, which
  says nothing about the horizontal, so anything wider than its panel — a diff,
  which deliberately does not wrap — was centred and clipped at both ends.
- Every screenshot opened with 78pt of nothing in the top left. The bar keeps
  that much clear for the traffic lights, and `WindowChrome` can only answer
  for a window — an `ImageRenderer` pass has none, so it kept saying the lights
  were there and the gutter was held for buttons that could not be drawn. A
  snapshot now takes the same 12pt inset the app uses in full screen, where
  there are no lights either. Nothing changes in a window.
- **The app still said `~/.forge` in three places** — the empty state, the New
  workspace sheet and the path preview under every repository you pick — four
  releases after the rename. Workspaces have been checked out under `~/.meshvy`
  since 0.7.0, so the one place that told you where your repositories were
  going was naming a directory that does not exist.
- `--selftest` takes `--name` and `--branch`, which is how `make-shots.sh`
  builds its board: the same path a person takes, so the shots are of a
  workspace made the way workspaces are made.

## [0.10.3] - 2026-10-12

No change to the app itself — this one is about what surrounds it.

- **Stapling now checks that it took.** 0.10.2 never shipped: `stapler staple`
  reported success on the app, and two steps later the ticket was not there.
  It was never reproduced, and Gatekeeper accepted the build regardless because
  it can look a ticket up online — but a stapled ticket is the entire point of
  stapling, since it is what lets the app open on a machine that is offline or
  behind a filter. Both the staple and the ticket fetch are idempotent and cost
  nothing, so it now validates after stapling and retries rather than shipping
  a build that is notarised in name only.
- `verify-release.sh` repeats what stapler actually said instead of reporting
  every failure as "no notarisation ticket". The generic message is what made
  the above take an hour to pin down: it hid the difference between a ticket
  that was never fetched and one that could not be checked.

- **Release pages carry the changelog.** They listed how to install and the
  checksums, and said nothing about what had changed; the prose only ever
  existed in `CHANGELOG.md`. The publish step now lifts the section for the
  version being tagged, so the page and the repository cannot drift apart.
- `scripts/release.sh` was advising that the branch and the tag be pushed in
  one go, which is how 0.10.0 came to fail on the release runner after CI had
  reported success: the tag starts the build, the sign, the notarisation and
  the publish before anything has checked the commit. It now gives the order
  and the reason.
- The README no longer tells people releases are unsigned, since they are not.
  The old advice survives as one line for anyone still on an earlier build —
  those stay unsigned forever and will go on being refused.

## [0.10.1] - 2026-10-12

- **Signed and notarised.** Releases carry a Developer ID signature and an
  Apple notarisation ticket, so a download opens without *“Apple could not
  verify Meshvy is free of malware”* and without anyone having to clear a
  quarantine flag by hand. The install script and the in-app updater were
  already free of the warning — quarantine is only attached by the app doing
  the downloading — so this was the DMG's problem alone, and now it is nobody's.
- `scripts/verify-release.sh` says what Apple makes of a build and why: whether
  the signature verifies, whether it is a Developer ID or the ad-hoc one a
  local build gets, whether the hardened runtime and secure timestamp Apple
  requires are present, whether a ticket is stapled, and what Gatekeeper
  actually answers. Run it against `dist/` or against an installed copy.
- The release workflow takes the Gatekeeper warning in its notes from that
  verdict rather than from whether a secret happens to be set, and stops
  outright if credentials are present but the build came out unsigned. A
  release that claims to be signed while macOS refuses it is worse than one
  that admits it is not.
- Three things in the signing path that would each have bitten the first time
  a certificate was added: the app was signed with `--deep`, which Apple's own
  guidance says is for verifying rather than signing; the disk image was never
  signed, only the app inside it, though Gatekeeper judges the container
  separately; and the zip's notarisation and the app's stapling were both
  `|| true`, so a failure produced a half-notarised release that still shipped.
- The Gatekeeper advice in the README and in every release body was telling
  people to Control-click and choose **Open** — a bypass macOS 15 removed, so
  the first thing a new user was told to try could not work.
- `docs/signing.md` records where the key material lives, how to issue a new
  certificate or notarisation key without Xcode, and what expires when.

## [0.10.0] - 2026-10-12

- **A browser on the board.** A workspace gives you the repositories and the
  agents; what they are building is a running application, and until now the
  only way to look at one was to leave Meshvy. A browser node is a real page on
  the canvas — ⌘B, or right-click a repository — pointed at your dev server,
  sitting next to the agent writing it. It keeps cookies between launches and
  reopens where you left it.
- **Agents can drive it.** Every session Meshvy starts is given a `browser_*`
  tool set over MCP with no setup: `browser_snapshot` returns the page's text
  and every control with a CSS selector, and `browser_click`, `browser_type`,
  `browser_eval`, `browser_wait_for`, `browser_console` and
  `browser_screenshot` act on what it hands back. Typing fires the `input` and
  `change` events a framework listens for, so React and Vue forms see it.
  Agents are told to read the console before claiming a web change works, and
  the errors a page throws come back attached to the action that caused them.
  Tools rather than a shell helper, because driving a page is dozens of calls
  each with a structured result — which is what tools are for. The engine is
  WebKit rather than Chromium: it is what macOS can host inside a canvas node.
- **Model, effort and permission mode in one menu**, on the toolbar pill and on
  every agent card, and remembered for the next agent you open. On a card it
  retunes that session where the CLI allows it — `/model` and `/effort` take
  effect straight away; the permission mode is fixed at launch, so that one
  says to use ⇧⇥ or restart rather than pretending. `--effort` and the
  `dontAsk` permission mode are both new to the CLI and both now offered.
- **Archiving.** The three destructive paths — close, delete worktrees, delete
  and discard — all ask you to think. Most of the time what you want is
  neither: the branch is merged and you would like it out of the switcher.
  ⌥⌘A, or the box in the toolbar. Nothing on disk is touched; restore it from
  the workspace menu or the foot of the sidebar.
- **The top bar's traffic-light gutter.** In full screen the lights are parked
  in a title bar that slides over the content, so the 78pt the bar keeps clear
  for them is a gap in the corner with nothing in it. The bar used to hold its
  own copy of whether the lights were there, pushed to it once per change by a
  probe view — which had two ways to go wrong and no way to recover from
  either: the probe registered its observers on a delayed hop and gave up
  silently if its view had no window yet, and the push was de-duplicated at the
  sending end, so a copy that ever disagreed would never be told again. The
  state now lives in one shared `WindowChrome` the bar reads on every render,
  with observers registered for every window at first access rather than for
  one window once it exists. It cannot hold a stale answer, and any resize, app
  switch or key change re-syncs it.
  The gutter also has to survive a sheet: while **New workspace…** is up the key
  window is the sheet, which has no traffic lights of its own, and asking it
  would slide the bar under the real window's buttons.
- A browser node's address bar follows the canvas zoom like everything else on
  a card, and both it and the page give way to the header below half scale.
- **Adding a field no longer empties your board.** Swift's synthesised
  `Codable` ignores a property's default and insists on the key, so shipping
  one new field would have made every existing `workspaces.json` unreadable and
  the board would have come up blank. Workspaces, terminals and browsers now
  decode leniently, and `--formattest` reads a 0.9.0 board to prove it.
- `--browsertest` drives a real page in a real engine, speaks JSON-RPC to the
  generated MCP server as Claude Code does, and serves its own tool calls
  through the app. `--chrometest` measures the toolbar's gutter off the
  rendered window, sheet and all. `--chromeprobe <dir>` does the same against
  the window the app itself makes, in real full screen — it has to be launched
  through LaunchServices (`open -a Meshvy --args --chromeprobe /tmp/probe`),
  since macOS will not keep a window full screen for an app that is not
  frontmost, and it writes a report and corner crops rather than printing.
  `--snapshot --browser <url>` puts a browser on a docs shot.

## [0.9.0] - 2026-10-11

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
