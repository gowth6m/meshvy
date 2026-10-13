# DesignSystem

**The shared visual vocabulary.**

`Theme` (colour, type, metrics), `Zoom` (how a dimension scales with the canvas), the small chrome views (`Pill`, `StatusDot`, `MetaStat`, `ChromeButton`, `SegmentedControl`), sheet primitives, `VSplit`, `ResizeHandle`, `BrandMark`, `WindowChrome`, and the snapshot-safe containers that let `ImageRenderer` draw a panel built on a `ScrollView`.

Depends on no feature and no state, so anything here can be previewed without booting the app. Everything is public: a component nobody can place is not a component.

## Depends on

- `MeshvyCore`
- `MeshvyModels`

## Files

- `BrandMark.swift`
- `Chrome.swift`
- `FlippedContainer.swift`
- `ResizeHandle.swift`
- `ScrollableStack.swift`
- `SegmentedControl.swift`
- `Sheets.swift`
- `Theme.swift`
- `VSplit.swift`
- `WindowChrome.swift`
- `Zoom.swift`

11 files, 1200 lines.

## Tests

No suite yet. Worth adding one for anything here that is a pure function of its inputs.
