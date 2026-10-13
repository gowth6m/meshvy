# Security

## Reporting a vulnerability

Please report privately rather than opening an issue.

Use [GitHub private vulnerability
reporting](https://github.com/gowth6m/meshvy/security/advisories/new) on this
repository — a draft advisory there reaches the maintainer and stays invisible
until it is published.

Useful in a report: what an attacker can do, how to reproduce it, the Meshvy
version, and whether you were running a release build or one from source.

This is a small project, not a company with an on-call rota. Expect a first
reply within about a week. There is no bug bounty. Fixes go out as a normal
release, with credit in the CHANGELOG unless you would rather not be named.

## What Meshvy is, in security terms

Worth being plain about, because it changes what counts as a vulnerability:
**Meshvy is a tool for running AI coding agents against your own code, with
broad permissions, on purpose.**

It starts real `claude` processes in real PTYs, in git worktrees cut from your
repositories, and by default it pre-approves some of what they do so an
orchestrator is not stopped every few seconds for permission. An agent doing
something destructive to a workspace is the tool working as designed, not a
vulnerability. The things that *would* be vulnerabilities are below.

### Trust boundaries

**The agent is not a trusted party.** It is driven by a model acting on a
prompt, and that prompt can come from a repository you cloned, a web page it
was asked to read, or an issue someone filed. Prompt injection is a real path
into this app. So:

- An agent is confined to the worktrees of its workspace, under `~/.meshvy/`,
  and the per-workspace plumbing in `<workspace>/.meshvy/`. Anything that lets
  an agent reach outside that — write to another workspace, to the app bundle,
  or to your real checkout rather than its worktree — **is a vulnerability.**
- Meshvy pre-approves `Bash(meshvy:*)` and the `browser_*` MCP tools. Anything
  that widens that in practice — a `meshvy` subcommand that runs arbitrary
  argv, an MCP tool that reads a path it was not given — **is a
  vulnerability.**
- The delegation protocol is files on disk (`<workspace>/.meshvy/requests/`),
  read by the app and acted on. A malformed or hostile request file that makes
  Meshvy start a process outside the workspace, or crash in a way that is
  exploitable, **is a vulnerability.**

**The browser node renders untrusted pages.** An agent can point it anywhere.
Console output and page snapshots come back into the app as data. Anything that
turns page content into code execution in Meshvy, or that lets a page read
state belonging to another node, **is a vulnerability.**

### Credentials

- Meshvy does not ask for, store, or transmit your Anthropic credentials. It
  shells out to the `claude` CLI, which handles its own auth.
- An optional Anthropic API key, used only to list available models, is stored
  in the **macOS Keychain** (service `dev.gowtham.meshvy`,
  `kSecAttrAccessibleAfterFirstUnlock`). It is never written to the layout
  file, the board file, or a log. A path that leaks it — into a transcript, an
  agent's environment, a crash report — **is a vulnerability.**

### Updates

The updater reads the GitHub releases feed, downloads the archive, and checks
it against the published `SHA256` asset before swapping the bundle. Releases
are signed with an Apple Developer ID and notarised when the signing secrets
are configured; `Scripts/verify-release.sh` is what decides whether a build is
notarised, by asking the artifact rather than by assuming.

Anything that lets an attacker get an unexpected bundle installed — a downgrade
that is accepted, a checksum that is skipped when absent rather than refused, a
redirect to a host that is not GitHub — **is a vulnerability.**

### Not currently in scope

Stated so you do not spend time on it:

- **The app is not sandboxed.** It cannot be: it runs arbitrary developer
  tooling in your repositories. "Meshvy can read files outside the sandbox" is
  not a finding.
- **Agents cost money and can be made to cost more.** A prompt that makes an
  agent burn tokens is a product problem, not a security one.
- **Unsigned local builds.** A build you made yourself is as trustworthy as
  your machine.

## Supported versions

The latest release. Meshvy is pre-1.0 and ships from `main`; fixes go into the
next release rather than being backported.
