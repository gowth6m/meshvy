# Floorplan engine, as bundled in Meshvy

This folder is [Floorplan](https://github.com/gowth6m/floorplan) 0.11.0
(commit `94f81b4`), MIT-licensed by Hayden Smith (see `LICENSE`). It is the
engine behind Meshvy's workspace map: the scripts that scan the repositories,
the skill that tells Claude how to describe them, and the self-contained map
page.

`Scripts/build-app.sh` copies `skills/floorplan/` into the app as
`Contents/Resources/floorplan/`. `FloorplanKit` finds it there, and Meshvy runs
it with the `node` it finds on the Mac.

## What is different from upstream

Kept small on purpose, so a newer Floorplan can be dropped in and the list
below reapplied:

- **No waitlist.** `assets/ui/50-cloud.js`, the "Floorplan Cloud" card, is
  removed, and `WAITLIST_URL` in `assets/serve.mjs` defaults to empty, so the
  map never contacts a server other than its own on `127.0.0.1`.
- **No plugin packaging.** The Claude Code and Codex plugin manifests, the
  Codex agent file (`skills/floorplan/agents/`), the docs, and the release
  tooling are left out. Meshvy is the host now.
- **Tests.** `tests/release.test.mjs` and the checksum and plugin-manifest
  checks in `tests/supply-chain.test.mjs`, which test that packaging, are
  removed. The network check now says the engine never leaves the machine.

## Updating

1. Copy `LICENSE`, `package.json`, `skills/` and `tests/` from a newer
   Floorplan over this folder.
2. Reapply the list above.
3. `cd Engine/Floorplan && npm test`, which CI also runs.
