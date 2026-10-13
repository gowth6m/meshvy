# 1. One package, many modules

Accepted · 2026-10-13

## Context

Meshvy was one SwiftPM target: 61 files, ~16.7k lines, laid out by technical
category (`Model/`, `Services/`, `Store/`, `UI/`). That layout was holding up
well — a dependency scan found only four places where a lower layer reached
upwards — but it gives a contributor no way to answer "what is the canvas?"
without reading six directories, and it gives a reviewer no way to stop the
next cross-layer reach.

The goal is a codebase many contributors can work in at once without stepping
on each other, which needs three things the single target cannot provide:

- **Enforcement.** `internal` in a one-target app means "visible to all 16.7k
  lines". Nothing but review stops the inspector reaching into the canvas.
- **Ownership.** `CODEOWNERS` can name a directory, but a directory that holds
  a third of the UI is not an owned thing.
- **Build times.** Every edit recompiles everything.

## Decision

One package, nineteen library modules plus the app executable, with
dependencies declared per module in
`Package.swift` and a tier order the graph must respect.

Modules are organised by **feature and capability**, not by technical category:
`CanvasUI` holds the canvas and its node views; `AgentKit` holds everything
about driving an agent. The two exceptions are the bottom of the graph —
`MeshvyCore` and `MeshvyModels` are shared vocabulary by definition — and
`AppState`, which is discussed in [ADR 2](0002-appstate-bottleneck.md).

Each module directory is shaped like a package already
(`Packages/<Tier>/<Name>/Sources/<Name>/`), so promoting one to a standalone
package is a change to the manifest and nothing else.

## Why not twenty separate packages

The original plan called for a package per module, each with its own
`Package.swift`. Rejected for now:

- Compiler enforcement is **identical**. SwiftPM checks target dependencies
  exactly as strictly as package dependencies; `internal` is per-module either
  way. The thing we are buying the boundaries for, we already get.
- Twenty manifests is twenty files to keep in step, and resolution gets slower.
- A contributor cannot usefully clone one module of a macOS app anyway. The
  thing you run is the app.

What separate packages would add is the ability to version and release a module
independently. Nothing here is consumed outside the app, so that is worth
nothing today. **Trigger to revisit:** the first time a module gets a consumer
outside this repository, promote that module and leave the rest alone.

## Why not FeatureAPI / FeatureCore / FeatureUI

The original plan suggested splitting complex features into three modules each.
At this size that is five to ten times more modules than there is code to put
in them — `UpdateKit` is 430 lines, and an API/Core/UI split of it would be
three files of `public` restatement. The split earns its keep when two features
need to talk without seeing each other's internals; today they talk through
`AppState`.

**Trigger to revisit:** when a feature is depended on by three or more
*sibling* features, split its contracts into `<Feature>API`.

## Consequences

- A module may depend only on lower tiers. `Tools/check-architecture.py`
  enforces this in CI, because SwiftPM enforces the edges but not their
  direction — nothing in a manifest stops `AppShell` appearing in
  `MeshvyCore`'s dependencies.
- Crossing a module boundary now costs `public`, and for SwiftUI views an
  explicit `public init`. That cost is the point: it makes "should this be
  shared?" a decision rather than an accident.
- Incremental builds recompile a module and its dependents, not the app.
