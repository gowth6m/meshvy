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
    /// A dispatched sub-agent, which has a title, a task and a result to show.
    public static let subAgentNode = CGSize(width: 256, height: 108)

    // MARK: Minimums
    //
    // How small each kind of node may be dragged. Every node on the board can
    // be resized, so every kind needs a floor — and the floor is not the same
    // for all of them. A card stops where its own text stops fitting; a node
    // hosting a terminal stops where a shell prompt stops fitting, which is a
    // good deal wider. Dropping below these does not clip, it reflows into
    // nonsense, so they are enforced in the geometry rather than left to the
    // view to cope with.

    /// A session or sub-agent card: title, one line, and a footer.
    public static let minimumCard = CGSize(width: 190, height: 84)
    /// A terminal. Roughly 40 columns of the default font, plus the chrome.
    public static let minimumTerminal = CGSize(width: 320, height: 180)
    /// A browser. Narrower than this and the address bar loses its buttons
    /// before the page loses anything.
    public static let minimumBrowser = CGSize(width: 320, height: 220)
    /// The workspace node, which carries a chip per repository across its head
    /// before the terminal underneath gets any room at all.
    ///
    /// Shorter than `Workspace.idleHeight` (186) on purpose: that is the height
    /// the node collapses to with nothing running in it, and a floor above it
    /// would mean the node could be dragged taller and then never put back.
    public static let minimumWorkspace = CGSize(width: 420, height: 170)

    /// Space left between nodes lined up by hand. The same gap the composer
    /// lays a fresh board out with, so a tidied row sits in the grid the rest
    /// of the board already follows.
    public static let tidyGap: CGFloat = 26

    /// How tall each band of a node's chrome is.
    ///
    /// These are here, rather than written into each node view, because two
    /// different things have to agree on them: the view that lays the band out,
    /// and the canvas, which needs to know where a node's live content begins —
    /// the scroll wheel must not reach through a header into a terminal's
    /// scrollback. When those two kept their own numbers they drifted, and a
    /// band you could see was not the band the canvas was testing against.
    public enum Chrome {
        /// Title row of a terminal and of a browser.
        public static let header: CGFloat = 28
        /// Title row of the workspace node, which carries two lines.
        public static let workspaceHeader: CGFloat = 42
        /// The row of repository chips under it.
        public static let repoStrip: CGFloat = 35
        /// `AgentStatusStrip`, under the header of anything running an agent.
        public static let statusStrip: CGFloat = 18
        /// A browser's address bar.
        public static let addressBar: CGFloat = 30
        /// A `Divider`, which sits under each of the above.
        public static let rule: CGFloat = 1
    }
}
