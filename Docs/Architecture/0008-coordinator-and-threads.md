# 8. Coordinator and threads

Accepted · 2026-10-22

## Context

A workspace had an **orchestrator** on its node and **agents** it spawned, one
per repository. The pieces worked, but the model they added up to was hard to
hold in your head:

- An agent was *per repository*, not per piece of work. Work that touched two
  repositories was two agents with nothing tying them together, and work that
  belonged at the workspace root had nowhere to go — `meshvy spawn` refused a
  task without a repository.
- Agents had no names. A card was titled with the first 48 characters of its
  task, and the sidebar's **Agents** list mixed the orchestrator, every agent
  and every shell, sorted by a lifecycle state (`waiting`, `done`, `ended`)
  that answers "what is the process doing" rather than "do I need to look".
- The orchestrator only learned that an agent had finished by blocking on
  `meshvy wait`. While it waited it could not talk to you, and if it did not
  wait it never found out.
- Nothing was ever finished. A board kept every agent it had ever had, at the
  same weight.

Claude Code's projects answer the same problem with a shape people already
know: one main chat, where a **coordinator** takes requests and starts a
**thread** for each piece of work; threads report back; the coordinator sends
follow-ups to the thread that owns the work and tells you briefly how it went;
finished threads are resolved.

## Decision

Meshvy follows that model. It is a change of roles and of vocabulary, not of
machinery: every thread is still a real `claude` in a real PTY on the board,
started through the same request files.

**The coordinator** is the session on the workspace node. Its brief
(`AgentCommand.coordinatorBrief`) tells it it is the main chat: plan, answer
quick questions, hand each separate piece of work to a thread, route
follow-ups to the thread that owns the work, and report back in a line or two
naming the thread by its title.

**A thread** is one piece of work. `meshvy thread "<title>" "<task>" [--repo
<repo>]` starts one, in a repository or at the workspace root. Its brief
(`AgentCommand.threadBrief`) tells it to carry the work through and end each
turn with a short report that leads with the result, or with the one question
only the person can answer. Every thread has a short id (`bridgeID`) — also
the ones you start yourself — so the coordinator can address any of them.

**Threads report back.** When a thread's hooks say it finished a turn or
stopped on a permission question, the store types one line into the
coordinator's terminal (`AgentBridge.report`):

    [meshvy] Thread “Fix login” (a1b2c3) finished its turn: … — meshvy context a1b2c3 for more.

It is one line because a newline would submit it half-written, and it is
prefixed because the coordinator would otherwise take it for you; its brief
says so. Claude Code queues what is typed mid-turn, so a busy coordinator reads
it when it is done. `meshvy wait` still exists for a coordinator that wants to
block.

**Where a thread stands** is `ThreadState`, derived and never stored: *Needs
you*, *Ready* (finished a turn), *Working*, *Idle*, *Stopped* (its process is
gone), *Resolved*. The only thing a thread remembers is `resolvedAt`.
Resolving takes a thread out of the open list and nothing else — no process is
stopped and nothing leaves the board — and any new turn, from you or from
`meshvy send`, reopens it.

**The UI says the same thing.** The sidebar is the project: *Coordinator*, then
*Threads* sorted by what wants you, then *Resolved* folded away, with shells in
a list of their own. A thread's card carries its state where the role label
used to be. "Orchestrator" reads "Coordinator" and "Agent" reads "Thread"
everywhere the user can see them.

## Consequences

- **Saved boards are untouched.** The on-disk names stay as they were —
  `Workspace.orchestrator`, `TerminalNode.Role.orchestrator` and `.repo` — so
  every board decodes with no migration (ADR 4). Only display strings and the
  briefs changed. Code that is not persisted uses the new words
  (`startCoordinator`, `AgentCommand.thread`).
- **The older helper commands keep working.** `meshvy spawn <repo> "<task>"`
  becomes a thread titled from its task, and `meshvy status` is `meshvy
  threads`, so a coordinator briefed by an older build still gets answers.
- **Text reaches the coordinator that you did not type.** The report carries
  the first line of a thread's last message. That is no new boundary — the
  coordinator already read the same text through `meshvy wait` and `meshvy
  context` — but it now arrives unasked. It is one line, capped at 300
  characters, and labelled as coming from Meshvy.
- **Typing into a terminal you may be typing into.** A report that lands while
  you are halfway through a message to the coordinator joins your line. The
  alternative — holding reports until the coordinator is idle *and* its prompt
  is empty — means reading the terminal's screen for agent state, which
  Meshvy deliberately does not do (see `AgentHooks`). Revisit if it bites.
