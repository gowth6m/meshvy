# Changelog

## [0.8.0] - 2026-10-11

Delegated agents are real terminals now.

- **The orchestrator spawns actual Claude Code sessions.** Claude's Agent tool
  runs sub-agents inside the parent process — they have no pid and no pty, so
  there was nothing a terminal node could attach to and they could only be
  drawn as cards. The orchestrator is now told to delegate with a `meshvy`
  helper placed on its PATH instead; each agent it starts is a real session
  with its own terminal on the canvas, linked back to the workspace node.
- `meshvy spawn | wait | send | list` — including `send`, which types one
  agent's message into another's terminal.
- The helper is pre-approved (`Bash(meshvy:*)`), because `acceptEdits` does not
  cover Bash and an orchestrator that stops to ask permission for every spawn
  never gets going.
- The agent bridge starts with the workspace rather than with the orchestrator,
  so any terminal can delegate.
- Agent-tool sub-agents still appear as cards if one is used anyway, so no work
  goes invisible.
- One store per process. The scene and the headless harnesses were each making
  their own, which meant two sets of timers, two filesystem watchers, and two
  readers racing for the same bridge requests.

## [Unreleased]

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
