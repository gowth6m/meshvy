# 5. What `public` means here

Accepted · 2026-10-13

## Context

Splitting one target into twenty makes access control load-bearing for the
first time. `internal` used to mean "anywhere in the app"; now it means "inside
this module", and every type another module touches needs `public` — plus, for
a SwiftUI view, an explicit `public init`, because the memberwise initialiser
is internal.

Done thoughtlessly, that ends with `public` on everything and twenty modules
with no encapsulation at all, which is the old single target with extra steps.

## Decision

Three different policies, by what the module is for.

**Vocabulary modules — `MeshvyCore`, `MeshvyModels`.** Everything is public.
These exist to be shared; a `Workspace` nobody outside can read is not a model.
"Minimal API" for a vocabulary module *is* all of it.

**Component library — `DesignSystem`.** Everything is public, for the same
reason: a component nobody can place is not a component.

**Everything else — the platform kits, the capability kits, the feature UIs.**
Public only where another module actually uses it. The surface was computed
from the real reference graph rather than guessed, and anything only used
inside its own module stayed internal.

**Mutability.** State on `MeshvyStore` that a feature reads but must not write
is `public internal(set)` — readable anywhere, writable only inside `AppState`.
This replaces the `private(set)` the single target used, and is the same
guarantee: the store's own code writes it, nobody else does.

## Consequences

- Adding a type to a feature module costs nothing. Letting another module see
  it costs a deliberate `public`, which is a reviewable event.
- SwiftUI views that cross a boundary carry an explicit `public init`. Tedious,
  and the tedium is informative: a view with fifteen initialiser parameters is
  telling you it should not be shared.
- `Tools/check-architecture.py` covers the direction of dependencies; it does
  not and cannot tell you a `public` was unnecessary. That stays a review
  question: *does anything outside this module use it?*
