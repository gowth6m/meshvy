# Changelog

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
