# 7. One answer about the pointer

Accepted · 2026-10-19

## Context

The board had three separate ideas of where a node begins and ends, and they
disagreed.

`CanvasView.chromeHeight(of:)` returned 29, 48, 78 or 60 depending on the node
kind, and those numbers had to match a `.frame(height:)` written by hand in
`TerminalNodeView`, `WorkspaceNodeView` and `BrowserNodeView`. Two different
things read it — the drag that moves a node, and the test that decides whether
the scroll wheel reaches a terminal's scrollback — and a fourth place,
`scrollable(under:)`, re-derived it again.

Resizing was a bespoke `resizeGrip` inside each of the three live node views,
each with its own minimum size, its own 8pt glyph in one corner, and in the
workspace's case an `opacity(isRunning ? 1 : 0)` that hid the control exactly
when the node was at its smallest. Session and sub-agent cards could not be
resized at all, because nobody had written a fourth grip.

Linking was a `+` that appeared on one edge of a node that was already
selected, positioned with canvas coordinates inside an overlay whose origin was
the card's own top-left — so it landed off its node for every node not at the
viewport origin.

Each of those is the same bug: **a question about the pointer answered in more
than one place.**

## Decision

Every question about where the pointer is gets one answer, and that answer
lives below the view layer.

**`MeshvyCore/CanvasGeometry.swift`** is pure arithmetic on rectangles:
`resize(_:from:by:minimum:)`, `handle(at:of:touch:)`, `isOnBorder`,
`edge(at:of:reach:corner:)`, `snap(_:to:within:)`, `HandleFit`, and the
constants the three consumers share — `handleTouch`, `borderGrab`, `edgeReach`,
`linkOffset`, `linkTouch`. It has no platform and no UI, so it has unit tests
that run in CI without an app.

**`MeshvyModels/CanvasNode`** gains `chromeHeight`, `minimumSize` and
`hostsLiveContent`, derived from `BoardMetrics.Chrome` — the same constants the
node views now lay themselves out with. The cross-file invariant is gone rather
than hand-maintained.

**`CanvasUI/NodeFrame`** is one view that draws the selection frame, the eight
resize handles and the four link handles for all five node kinds. The thing
that draws a handle is the thing that hit-tests it, so they cannot drift.

Two numbers in that file are load-bearing together: a side resize handle and a
link handle sit on the same point of the same edge, and their targets must not
overlap. That is not a comment, it is `CanvasGeometry.handlesAreDisjoint` and a
test that fails if anyone re-picks them. It failed the first time it was run.

## Why the geometry is in MeshvyCore and not DesignSystem

`DesignSystem` is where a shared *view* goes. This is not a view — it is the
layout maths `AppState` also needs, to lay a board out and to line a dragged
node up against its neighbours, and `AppState` may not depend on a UI module
(ADR 2). `BoardMetrics.sessionNode` was already in `MeshvyCore` for exactly
this reason; the rest of the board's measurements now sit beside it.

## Why not an AppKit canvas

A single `NSView` with `hitTest` and `cursorUpdate` would answer all of this
natively, and it is what a drawing app would do. It was rejected because the
nodes are not drawings: three of the five host live AppKit views that a SwiftUI
`NSViewRepresentable` already parents correctly, with registry-owned lifetimes
that must survive every pan, zoom and rebuild. Rewriting the hosting to hang
off a hand-rolled canvas risks the one thing this app cannot afford to break —
a PTY being torn down — to win cursor handling.

What that costs, and what it would take to revisit: SwiftUI gives no modifier
flags on a drag and no scroll wheel outside a `ScrollView`, so the board runs
four local `NSEvent` monitors. **Trigger:** if a fifth is needed, or if a
gesture cannot be expressed without reading an event the monitors have already
consumed, put one `NSView` under the canvas and move hit-testing into it —
keeping the node hosting exactly as it is.

## Consequences

- Every node kind moves, resizes and links by the same gestures, because there
  is one implementation rather than three plus two missing ones.
- Card sizes are user state, so `SavedLayout` gained `sizes` — **optional**,
  for the reason [ADR 4](0004-forward-compatible-persistence.md) writes down: a
  synthesised decoder insists on every non-optional key however many defaults
  it carries, and `FileStore.load`'s `try?` turns that into a board that opens
  with the camera, the panel widths and every pinned node forgotten. ADR 4's
  own next step — a hand-written lenient `init(from:)` for `SavedLayout` — is
  deliberately still not taken here, for the reason it gives: it is a change to
  persistence and should not land inside a change to the board.
- `swift test` still cannot run on a Command Line Tools machine, so the same
  ground is covered twice: `CanvasGeometryTests` for CI, and
  `Meshvy --canvastest` for the store, the workspace model and `layout.json`
  as they actually behave.
- What none of it can show is whether a press still reaches SwiftTerm. That is
  a human at the keyboard, and it stays that way.
