import AppKit
import DesignSystem
import MeshvyCore
import SwiftUI
import TerminalKit

/// Draws a terminal's current screen as plain text.
///
/// `ImageRenderer` cannot draw an `NSViewRepresentable`, so a terminal is blank
/// in every `--snapshot`. Reading the emulator's own screen buffer and setting
/// it in a monospaced font keeps documentation shots honest — it is the real
/// output of the real session, just drawn by SwiftUI rather than SwiftTerm.
public struct TerminalSnapshotText: View {
    public var session: TerminalSession
    public var zoom: Zoom

    public init(
        session: TerminalSession,
        zoom: Zoom
    ) {
        self.session = session
        self.zoom = zoom
    }

    public var body: some View {
        Text(trimmed)
            .font(.system(size: max(5, 7.4 * zoom.scale), design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(zoom.s(6))
            .background(Theme.canvasDeep)
            .clipped()
    }

    /// The emulator pads every row to the full width; the trailing blanks waste
    /// the card and push the real output off the bottom.
    private var trimmed: String {
        session.screenText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .drop { $0.isEmpty }
            .reversed().drop { $0.isEmpty }.reversed()
            .joined(separator: "\n")
    }
}

/// Hosts a registry-owned terminal view.
///
/// The terminal is laid out at its *world* size and magnified to fill the
/// projected frame. That way zooming scales the text like everything else on
/// the board, instead of the grid reflowing and the glyphs staying 11.5pt
/// however far you zoom in — which was the one thing on the canvas whose size
/// never responded to the zoom control.
public struct TerminalSurface: NSViewRepresentable {
    public var session: TerminalSession
    /// Canvas zoom. The world size is derived from the frame SwiftUI hands the
    /// container, rather than passed in: the card's chrome (header, status
    /// strip, dividers) comes out of the terminal's share of the node, and
    /// quoting the node's own size here stretched the glyphs by whatever that
    /// chrome happened to be.
    public var scale: CGFloat
    /// True while the node is being resized. The terminal keeps the grid it
    /// had until this goes false again — see `FlippedContainer.heldSize`.
    public var holdsGrid: Bool

    public init(
        session: TerminalSession,
        scale: CGFloat,
        holdsGrid: Bool = false
    ) {
        self.session = session
        self.scale = scale
        self.holdsGrid = holdsGrid
    }

    public func makeNSView(context: Context) -> NSView {
        let container = FlippedContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: Theme.Hex.canvasDeep).cgColor
        // A held grid can be bigger than a node being shrunk around it.
        container.clipsToBounds = true
        container.addSubview(session.surface)
        container.scale = scale
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? FlippedContainer else { return }
        if session.surface.superview !== container {
            session.surface.removeFromSuperview()
            container.addSubview(session.surface)
        }
        container.scale = scale
        if !holdsGrid {
            container.heldSize = nil
        } else if container.heldSize == nil {
            container.heldSize = session.surface.frame.size
        }
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }
}
