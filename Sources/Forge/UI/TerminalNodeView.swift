import AppKit
import SwiftUI

// SwiftTerm exports its own `Color`, which would shadow SwiftUI's throughout
// this file, so it is not imported here — the terminal view is reached through
// `TerminalSession` and typed as a plain `NSView`.

/// A live terminal sitting on the canvas.
///
/// The `LocalProcessTerminalView` is owned by `TerminalRegistry`, not created
/// here — SwiftUI rebuilds this view on every pan and zoom, and making the view
/// in `makeNSView` would kill and restart the shell each time.
struct TerminalNodeView: View {
    var node: TerminalNode
    @Bindable var store: ForgeStore
    var zoom: Zoom
    var isSelected: Bool
    var isDimmed: Bool
    var onResize: (CGSize) -> Void

    private var session: TerminalSession? { store.terminals.session(for: node.id) }
    private var isRunning: Bool { session?.isRunning ?? false }

    private var accent: SwiftUI.Color {
        switch node.role {
        case .orchestrator: return Theme.accent
        case .repo: return Theme.worktree
        case .shell: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            content
        }
        .background(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .fill(Theme.canvasDeep)
        )
        .clipShape(RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(Theme.nodeCorner), style: .continuous)
                .stroke(
                    isSelected ? Theme.accent : accent.opacity(isRunning ? 0.45 : 0.2),
                    lineWidth: isSelected ? max(1, zoom.s(1.8)) : max(0.5, zoom.s(1))
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.35), radius: zoom.s(isSelected ? 18 : 10), y: zoom.s(5))
        .opacity(isDimmed ? 0.25 : 1)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    private var header: some View {
        HStack(spacing: zoom.s(6)) {
            Image(systemName: node.role.icon)
                .font(zoom.font(10, .semibold))
                .foregroundStyle(accent)
            Text(node.title)
                .font(zoom.font(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text(node.role.label.uppercased())
                .font(zoom.font(7.5, .heavy))
                .tracking(zoom.s(0.5))
                .foregroundStyle(accent.opacity(0.9))
                .padding(.horizontal, zoom.s(4))
                .padding(.vertical, zoom.s(1.5))
                .background(RoundedRectangle(cornerRadius: zoom.s(3)).fill(accent.opacity(0.14)))

            Spacer(minLength: 0)

            if !isRunning {
                Text("exited")
                    .font(zoom.font(9.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                Button { store.restartTerminal(node.id) } label: {
                    Image(systemName: "arrow.clockwise").font(zoom.font(9.5, .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Restart")
            } else {
                Circle().fill(Theme.clean).frame(width: zoom.s(5), height: zoom.s(5))
            }

            Button { store.closeTerminal(node.id) } label: {
                Image(systemName: "xmark").font(zoom.font(9, .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Close terminal")
        }
        .padding(.horizontal, zoom.s(10))
        .frame(height: zoom.s(28))
        .background(Theme.chrome)
    }

    @ViewBuilder
    private var content: some View {
        if let session {
            // Below roughly half scale the glyphs are unreadable anyway, and the
            // emulator does not scale — show the folder instead and keep the
            // process running untouched in the registry.
            if zoom.scale > 0.5 {
                TerminalSurface(session: session)
            } else {
                placeholder
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: zoom.s(5)) {
            Image(systemName: "terminal")
                .font(zoom.font(16, .light))
                .foregroundStyle(Theme.textTertiary)
            Text(node.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(zoom.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasDeep)
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(zoom.font(8, .bold))
            .foregroundStyle(Theme.textTertiary)
            .padding(zoom.s(4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onResize(CGSize(
                            width: max(320, node.size.width + value.translation.width / zoom.scale),
                            height: max(200, node.size.height + value.translation.height / zoom.scale)
                        ))
                    }
                    .onEnded { _ in store.commitTerminalMove() }
            )
    }
}

/// Hosts the registry-owned terminal view.
private struct TerminalSurface: NSViewRepresentable {
    var session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = FlippedContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(srgbRed: 0.035, green: 0.039, blue: 0.051, alpha: 1).cgColor
        container.addSubview(session.surface)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-parent if this surface was rebuilt into a different container.
        if session.surface.superview !== nsView {
            session.surface.removeFromSuperview()
            nsView.addSubview(session.surface)
        }
        session.surface.frame = nsView.bounds
    }

    /// Lays the terminal out from the top-left, matching the card.
    final class FlippedContainer: NSView {
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds
        }
    }
}
