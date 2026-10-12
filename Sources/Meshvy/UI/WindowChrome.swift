import AppKit
import Observation
import SwiftUI

/// Whether the window buttons are on screen.
///
/// The top bar keeps 78pt clear at its leading edge for the traffic lights, and
/// has to give that space back when there are none — in full screen they are
/// parked in a title bar that slides over the content instead, so a gutter left
/// behind for them is a gap in the corner with nothing in it.
///
/// It is a shared observable rather than a value pushed into the bar, which is
/// what it used to be, because a pushed value has two ways to go wrong and no
/// way to recover from either. The old probe registered its observers on a
/// delayed hop and gave up silently if its view had no window yet, so a launch
/// that lost that race never heard about full screen at all. And the push was
/// de-duplicated at the sending end, so if the bar's own copy ever disagreed —
/// a fresh `@State`, say — nothing would ever tell it again.
///
/// Here the bar reads this on every render, so it cannot hold a stale answer,
/// and the observers are registered for *every* window at first access rather
/// than for one window once it exists, so there is nothing to miss.
@MainActor
@Observable
final class WindowChrome {
    static let shared = WindowChrome()

    private(set) var trafficLightsVisible = true

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        // `object: nil` — any window. The scene's window does not exist yet the
        // first time a view asks for this, and an observer that waits for one is
        // an observer that can be missed.
        let names: [Notification.Name] = [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSApplication.didBecomeActiveNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(token)
        }
    }

    /// Re-reads the window. Cheap, and safe to call as often as you like: the
    /// value only ever lands when it has actually changed.
    func refresh() {
        guard let window = WindowChrome.subject else { return }
        let visible = !window.styleMask.contains(.fullScreen)
            && !(window.standardWindowButton(.closeButton)?.isHiddenOrHasHiddenAncestor ?? true)
        if visible != trafficLightsVisible { trafficLightsVisible = visible }
    }

    /// The window the chrome is about.
    ///
    /// Not simply `keyWindow`: a sheet is a window too, and while one is up it
    /// is the key window. A sheet has no traffic lights of its own, so asking it
    /// would answer "none" and slide the bar underneath the real window's
    /// buttons every time you opened **New workspace…**. Main first, since a
    /// sheet never becomes main.
    static var subject: NSWindow? {
        func qualifies(_ window: NSWindow) -> Bool {
            window.isVisible && window.canBecomeMain && !window.isSheet
        }
        if let main = NSApp.mainWindow, qualifies(main) { return main }
        if let key = NSApp.keyWindow, qualifies(key) { return key }
        return NSApp.windows.first(where: qualifies)
    }
}

/// Chrome that only AppKit can place.
///
/// The title bar is hidden so the top bar can own the full width, but AppKit
/// still parks the traffic lights nine points below the top of the frame —
/// eight above the centre line of a 48pt bar, which reads as a misalignment
/// next to the toolbar buttons. This centres them on the bar and puts them back
/// after the relayouts that reset it. Whether the bar leaves room for them at
/// all is `WindowChrome`'s business, not this one's.
struct TrafficLightLayout: NSViewRepresentable {
    /// Height of the bar the lights should be centred in.
    var barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.barHeight = barHeight
        // The probe reports when it lands in a window rather than being asked on
        // a delayed hop: a view handed to `makeNSView` has no window yet.
        let probe = Probe { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        coordinator.hold(probe)
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.barHeight = barHeight
        context.coordinator.attach(to: nsView.window)
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tells the coordinator which window it is in, every time that changes.
    @MainActor
    final class Probe: NSView {
        private let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }

    @MainActor
    final class Coordinator {
        var barHeight: CGFloat = 48
        private weak var window: NSWindow?
        private var probe: NSView?
        private var observers: [NSObjectProtocol] = []

        /// Keeps the probe alive for as long as SwiftUI keeps the coordinator.
        func hold(_ probe: NSView) {
            self.probe = probe
        }

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            detach()
            self.window = window
            guard window != nil else { return }
            observe()
            apply()
            // The bar's own inset comes from `WindowChrome`; a window appearing
            // is a good moment for it to take a fresh reading too.
            WindowChrome.shared.refresh()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func observe() {
            guard observers.isEmpty, let window else { return }
            // Every one of these relayouts the title bar and drops the nudge.
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
                observers.append(token)
            }
        }

        func apply() {
            // No window in snapshot rendering, where there is nothing to place.
            guard let window else { return }
            let buttons: [NSButton] = [.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard !window.styleMask.contains(.fullScreen),
                  !(buttons.first?.isHiddenOrHasHiddenAncestor ?? true)
            else { return }

            for button in buttons {
                // Window coordinates share the frame's origin, so the distance
                // from the top is measurable without knowing the title bar's
                // own geometry.
                let topInset = window.frame.height - button.convert(button.bounds, to: nil).maxY
                let moveDown = (barHeight - button.bounds.height) / 2 - topInset
                guard abs(moveDown) > 0.5 else { continue }
                button.frame.origin.y += button.superview?.isFlipped == true ? moveDown : -moveDown
            }
        }
    }
}
