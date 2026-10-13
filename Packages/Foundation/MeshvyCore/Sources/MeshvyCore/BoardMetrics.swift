import CoreGraphics

/// Sizes the board is laid out on.
///
/// These are design decisions, but the composer needs them before any view
/// exists: it places nodes in world coordinates, and a node's size is part of
/// where the next one goes. Keeping them here is what lets `AppState` lay out a
/// board without importing the design system — which would have put a module
/// full of views underneath the application state.
public enum BoardMetrics {
    /// A session card. Wide enough for a prompt line, short enough that a dozen
    /// of them fit across the screen at resting zoom.
    public static let sessionNode = CGSize(width: 268, height: 132)
}
