# 6. Where a second agent provider would plug in

Accepted · 2026-10-13

## Context

Meshvy drives Claude Code. The plan that prompted this refactor asked for an
`Integrations/` tier with `Claude/`, `Codex/` and `OpenCode/` packages, and an
`AgentSDK` module defining the contract between them.

## Decision

**Not built.** Three empty packages and a protocol with one conformance is
speculative generality — the same thing the plan warns against two bullets
later — and a contract designed against a single implementation reliably
encodes that implementation's accidents. The honest version is to know where
the seam goes and keep the code ready for it, which is what this ADR records.

## Where the seam is

`AgentKit` is already the only module that knows an agent provider exists, and
inside it the knowledge is concentrated:

| File | Claude-specific? | What it knows |
|---|---|---|
| `AgentCommand.swift` | **entirely** | the `claude` binary, its flags, the briefs |
| `ModelCatalog.swift` | **entirely** | Anthropic's model list and its API |
| `AgentHooks.swift` | mostly | the CLI's hook settings format and event shape |
| `AgentBridge.swift` | barely | a file protocol of Meshvy's own design |
| `SubAgentTracker.swift` | no | parses a transcript it is handed |
| `Notifier.swift` | no | posts notifications |

So the work is two files, not a tier. `AgentCommand` is the one place that
builds argv, and `--selftest`/`--hooktest` already cover it end to end.

Two leaks to fix first, both found while writing this:

- `MeshvyModels/Workspace.swift` has a `Role.shell` label and a `TerminalNode`
  shaped around "an agent session or a plain shell". That is provider-neutral
  already — good — but `sessionID` is documented in terms of
  `~/.claude/sessions`. The field is fine; the comment would need widening.
- `SessionKit` reads `~/.claude/projects` directly. A second provider with a
  different transcript format means `SessionKit` grows a notion of *which*
  provider a session came from, which is a bigger change than `AgentCommand`.

## What to do when the second provider arrives

1. Introduce `AgentProvider` **in `AgentKit`**, not a new module: the
   executable, how to build argv for an orchestrator and for a repo agent, how
   to install status hooks, how to list models.
2. Make the existing code `ClaudeProvider` conforming to it. The test suite
   should pass unchanged — if it does not, the protocol is wrong.
3. *Then*, with two conformances to compare, decide whether the protocol
   deserves its own module so a third party can implement it out of tree. With
   two real implementations that is a ten-minute judgement; with zero it is a
   guess.
4. `SessionKit` is the harder half. Budget for it separately.

**Trigger:** the first concrete request to run something other than Claude
Code, or the first contributor who wants to add one.
