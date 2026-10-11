import AppKit
import SwiftUI

/// Chrome that only AppKit can place.
///
/// The title bar is hidden so the top bar can own the full width, but AppKit
/// still parks the traffic lights nine points below the top of the frame —
/// eight above the centre line of a 48pt bar, which reads as a misalignment
/// next to the toolbar buttons. This centres them on the bar, puts them back
/// after the relayouts that reset it, and reports when they disappear into
/// full screen so the bar can reclaim the gutter it keeps clear for them.
struct TrafficLightLayout: NSViewRepresentable {
    /// Height of the bar the lights should be centred in.
    var barHeight: CGFloat
    /// Called when the lights appear or disappear, never for the same value twice.
    var onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.configure(barHeight: barHeight, onVisibilityChange: onVisibilityChange)
        context.coordinator.attach(to: probe)
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configure(barHeight: barHeight, onVisibilityChange: onVisibilityChange)
        context.coordinator.apply()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var barHeight: CGFloat = 48
        private var onVisibilityChange: (Bool) -> Void = { _ in }
        private weak var probe: NSView?
        private var observers: [NSObjectProtocol] = []
        private var reportedVisible: Bool?

        func configure(barHeight: CGFloat, onVisibilityChange: @escaping (Bool) -> Void) {
            self.barHeight = barHeight
            self.onVisibilityChange = onVisibilityChange
        }

        func attach(to probe: NSView) {
            self.probe = probe
            // A view has no window until it has been added to the hierarchy.
            DispatchQueue.main.async { [weak self] in
                self?.observe()
                self?.apply()
            }
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func observe() {
            guard observers.isEmpty, let window = probe?.window else { return }
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
            guard let window = probe?.window else { return }

            let buttons: [NSButton] = [.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            let visible = !window.styleMask.contains(.fullScreen)
                && !(buttons.first?.isHiddenOrHasHiddenAncestor ?? true)
            if visible != reportedVisible {
                reportedVisible = visible
                onVisibilityChange(visible)
            }
            guard visible else { return }

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
