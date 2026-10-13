import AppKit
import AppState
import BrowserKit
import DesignSystem
import MeshvyModels
import SwiftUI
import WebKit

/// A browser sitting on the canvas.
///
/// Same ownership rule as the terminal: the `WKWebView` belongs to
/// `BrowserRegistry`, not to this view. SwiftUI rebuilds node views on every pan
/// and zoom, and making the web view in `makeNSView` would reload the page each
/// time.
public struct BrowserNodeView: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    public var node: BrowserNode
    @Bindable public var store: MeshvyStore
    public var zoom: Zoom
    public var isSelected: Bool
    public var isDimmed: Bool
    public var onResize: (CGSize) -> Void

    public init(
        node: BrowserNode,
        store: MeshvyStore,
        zoom: Zoom,
        isSelected: Bool,
        isDimmed: Bool,
        onResize: @escaping (CGSize) -> Void
    ) {
        self.node = node
        self.store = store
        self.zoom = zoom
        self.isSelected = isSelected
        self.isDimmed = isDimmed
        self.onResize = onResize
    }

    @State private var typedURL = ""
    @State private var isEditingURL = false
    @FocusState private var urlFocused: Bool

    private var session: BrowserSession? { store.browsers.session(for: node.id) }
    private var problems: Int { session?.console.filter { $0.level == .error }.count ?? 0 }

    /// Browsers take the palette's purple, the one accent no other node uses —
    /// so on a board of agents the running application is the thing you can
    /// pick out without reading a word.
    private var accent: SwiftUI.Color { Theme.branch }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            // Below half scale the address bar is a row of mush, and the body
            // has already given up on drawing the page — so the card keeps its
            // header and says where it is pointed instead.
            if zoom.scale > 0.5 {
                addressBar
                Divider().overlay(Theme.hairline)
            }
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
                    isSelected ? Theme.accent : accent.opacity(0.4),
                    lineWidth: isSelected ? max(1, zoom.s(1.8)) : max(0.5, zoom.s(1))
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.55 : 0.35), radius: zoom.s(isSelected ? 18 : 10), y: zoom.s(5))
        .opacity(isDimmed ? 0.25 : 1)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .overlay(alignment: .bottom) { scrollHint }
        .onAppear {
            typedURL = node.url
            // A board restored from disk has the node but not the engine; this
            // is where the page actually comes back.
            _ = store.ensureBrowserRunning(node.id)
            // A blank node is one someone just opened from the menu, and the
            // only thing to do with it is say where to go.
            if node.url.isEmpty { urlFocused = true }
        }
        .onChange(of: node.url) { _, updated in
            guard !isEditingURL else { return }
            typedURL = updated
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: zoom.s(6)) {
            Image(systemName: session?.isLoading == true ? "globe.badge.chevron.backward" : "globe")
                .font(zoom.font(10, .semibold))
                .foregroundStyle(accent)
            Text(node.title)
                .font(zoom.font(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Text("BROWSER")
                .font(zoom.font(7.5, .heavy))
                .tracking(zoom.s(0.5))
                .foregroundStyle(accent.opacity(0.9))
                .padding(.horizontal, zoom.s(4))
                .padding(.vertical, zoom.s(1.5))
                .background(RoundedRectangle(cornerRadius: zoom.s(3)).fill(accent.opacity(0.14)))

            Spacer(minLength: 0)

            // The one thing worth interrupting you about: the page is throwing.
            if problems > 0 {
                Button { store.select(.browser(node.id)) } label: {
                    HStack(spacing: zoom.s(3)) {
                        Image(systemName: "exclamationmark.triangle.fill").font(zoom.font(8.5, .semibold))
                        Text("\(problems)").font(zoom.font(9.5, .bold))
                    }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, zoom.s(4))
                    .padding(.vertical, zoom.s(1.5))
                    .background(RoundedRectangle(cornerRadius: zoom.s(3)).fill(Theme.danger.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("\(problems) console \(problems == 1 ? "error" : "errors") — open the inspector to read them")
            }

            Text(node.shortID)
                .font(zoom.mono(9, .medium))
                .foregroundStyle(Theme.textTertiary)
                .help("How an agent addresses this browser")

            Button { store.closeBrowser(node.id) } label: {
                Image(systemName: "xmark").font(zoom.font(9, .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Close browser")
        }
        .padding(.horizontal, zoom.s(10))
        .frame(height: zoom.s(28))
        .background(Theme.chrome)
    }

    private var addressBar: some View {
        HStack(spacing: zoom.s(5)) {
            navButton("chevron.left", enabled: session?.canGoBack ?? false, help: "Back") {
                session?.goBack()
            }
            navButton("chevron.right", enabled: session?.canGoForward ?? false, help: "Forward") {
                session?.goForward()
            }
            navButton(
                session?.isLoading == true ? "xmark" : "arrow.clockwise",
                enabled: true,
                help: session?.isLoading == true ? "Stop" : "Reload"
            ) {
                if session?.isLoading == true { session?.stop() } else { store.reloadBrowser(node.id) }
            }

            SnapshotSafeField(
                placeholder: "localhost:3000", text: $typedURL, font: zoom.mono(10.5)
            )
            .focused($urlFocused)
            .onChange(of: urlFocused) { _, focused in
                isEditingURL = focused
                if !focused { typedURL = node.url }
            }
            .onSubmit {
                store.navigateBrowser(node.id, to: typedURL)
                urlFocused = false
            }
            .padding(.horizontal, zoom.s(7))
            .padding(.vertical, zoom.s(3))
            .background(
                RoundedRectangle(cornerRadius: zoom.s(5), style: .continuous).fill(Theme.fill)
            )

            if let error = session?.loadError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(zoom.font(10))
                    .foregroundStyle(Theme.dirty)
                    .help(error)
            }
        }
        .padding(.horizontal, zoom.s(8))
        .frame(height: zoom.s(30))
        .background(Theme.chrome.opacity(0.7))
    }

    private func navButton(
        _ icon: String, enabled: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(zoom.font(9.5, .semibold))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                .frame(width: zoom.s(18), height: zoom.s(18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let session, !isSnapshot, zoom.scale > 0.5 {
            BrowserSurface(session: session, scale: zoom.scale)
        } else if let poster = session?.poster, isSnapshot {
            // A documentation shot of a browser that showed a globe would be a
            // shot of the wrong thing. See `BrowserSession.capturePoster`.
            Image(nsImage: poster)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            placeholder
        }
    }

    /// Stands in wherever the real page cannot be drawn: too far zoomed out to
    /// read, or an `ImageRenderer` pass, which cannot draw a `WKWebView` at all.
    private var placeholder: some View {
        VStack(spacing: zoom.s(6)) {
            Image(systemName: "globe")
                .font(zoom.font(18, .light))
                .foregroundStyle(accent.opacity(0.7))
            Text(node.url.isEmpty ? "Nothing open yet" : (node.pageTitle ?? node.displayURL))
                .font(zoom.font(11, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(node.url.isEmpty ? "Type a URL above — localhost:3000 will do" : node.displayURL)
                .font(zoom.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(zoom.s(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasDeep)
    }

    /// The wheel pans the canvas until the pointer has rested on a node, which
    /// matters more for a page than for a terminal — most of what you want to
    /// look at is below the fold. Same dwell as the terminals.
    @ViewBuilder
    private var scrollHint: some View {
        if store.hoveredTerminal == node.id, store.armedTerminal != node.id, zoom.scale > 0.5 {
            Text("hold to scroll the page")
                .font(zoom.font(8.5, .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, zoom.s(6))
                .padding(.vertical, zoom.s(2))
                .background(Capsule().fill(Theme.chrome.opacity(0.9)))
                .padding(.bottom, zoom.s(6))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
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
                            height: max(240, node.size.height + value.translation.height / zoom.scale)
                        ))
                    }
                    .onEnded { _ in store.commitTerminalMove() }
            )
    }
}

/// Hosts a registry-owned web view, magnified by the canvas zoom.
///
/// Scaling the container's coordinate system rather than the web view's frame,
/// exactly as `TerminalSurface` does: the page keeps laying out at its own
/// width, so zooming the board does not reflow the site being tested.
public struct BrowserSurface: NSViewRepresentable {
    public var session: BrowserSession
    public var scale: CGFloat

    public init(
        session: BrowserSession,
        scale: CGFloat
    ) {
        self.session = session
        self.scale = scale
    }

    public func makeNSView(context: Context) -> NSView {
        let container = FlippedContainer()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: Theme.Hex.canvasDeep).cgColor
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
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }
}
