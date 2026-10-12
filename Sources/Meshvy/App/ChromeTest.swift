import AppKit
import SwiftUI

/// Checks the top bar's traffic-light gutter: `Meshvy --chrometest [--shots <dir>]`.
///
/// The bar keeps 78pt clear at its leading edge for the window buttons, and
/// reclaims it when there are no buttons to leave room for — which is what full
/// screen is. Whether it does rests on one callback firing, the kind of thing
/// that works until a timing detail changes and then silently leaves a gap in
/// the corner, so it is worth a harness rather than an eyeball.
///
/// Three passes, in a real window:
///
/// 1. **Windowed** — the first control should clear the lights at x=69.
/// 2. **Buttons hidden** — the state full screen actually puts the window in,
///    forced directly. The gutter should go.
/// 3. **A sheet on top** — the key window is then the sheet, which has no
///    traffic lights of its own. The bar must keep its gutter anyway.
/// 4. **Full screen** — toggled for real, and only *observed*: macOS will not
///    keep a window in a full-screen space for an app that is not frontmost,
///    which a harness launched from a shell is not. The trail prints what the
///    layout said, and the run does not hang on it; `--chromeprobe` is the one
///    that measures full screen for real.
///
/// Everything is measured off the rendered window rather than off the code that
/// computes it, and `--shots` keeps the PNGs — including a crop of the corner
/// being argued about. `cacheDisplay` draws in-process, so none of this needs
/// screen-recording permission.
@MainActor
enum ChromeTest {
    static func shotsDirectory(arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--shots"), flag + 1 < arguments.count else { return nil }
        return arguments[flag + 1]
    }

    static func probeDirectory(arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: "--chromeprobe"), flag + 1 < arguments.count else {
            return nil
        }
        return arguments[flag + 1]
    }

    // MARK: - The shipped window

    /// `Meshvy --chromeprobe <dir>`, run against the app's *own* window rather
    /// than one this file made.
    ///
    /// The difference matters. `--chrometest` builds its window by hand and has
    /// to fake full screen, because macOS will not keep a window in a
    /// full-screen space for an app that is not frontmost — and a binary started
    /// from a shell never is. Launched through LaunchServices (`open -a Meshvy
    /// --args --chromeprobe …`) the app *is* frontmost, the window is the one
    /// SwiftUI's `WindowGroup` made, and full screen is real.
    ///
    /// There is no console to print to, so the report is written to the
    /// directory, alongside a crop of the corner at each step.
    static func probeRealWindow(writingTo directory: String) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var report: [String] = []
        func say(_ line: String) { report.append(line) }

        Task { @MainActor in
            // The scene's window, once SwiftUI has made and shown it.
            var window: NSWindow?
            for _ in 0..<120 {
                window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.canBecomeMain }
                if window != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let window else {
                say("FAILED: the app never showed a window")
                finish(report, to: directory, ok: false)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))

            say(geometry(of: window, called: "first"))
            let windowed = measure(window, to: directory, named: "real-first")
            say("              first control at \(Int(windowed))pt")

            window.toggleFullScreen(nil)
            // The transition animates for about a second; give it two, then let
            // the bar settle before reading the pixels.
            for _ in 0..<40 where !window.styleMask.contains(.fullScreen) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(2))
            let held = window.styleMask.contains(.fullScreen)
            say(geometry(of: window, called: "toggled"))
            let full = measure(window, to: directory, named: "real-toggled")
            say("              first control at \(Int(full))pt  active=\(NSApp.isActive)")

            window.toggleFullScreen(nil)
            for _ in 0..<40 where window.styleMask.contains(.fullScreen) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(2))
            say(geometry(of: window, called: "back"))
            let restored = measure(window, to: directory, named: "real-back")
            say("              first control at \(Int(restored))pt")

            // The app may be launched into a restored full-screen space, so the
            // readings are judged by the state each was taken in rather than by
            // the order they came in.
            let states = [
                (window: windowed, full: !held),
                (window: full, full: held),
                (window: restored, full: !held)
            ]
            let inFullScreen = states.filter(\.full).map(\.window)
            let inWindow = states.filter { !$0.full }.map(\.window)
            let ok = !inFullScreen.isEmpty
                && inFullScreen.allSatisfy { $0 > 0 && $0 <= 24 }
                && inWindow.allSatisfy { $0 >= 70 }
            if inFullScreen.isEmpty { say("NOTE: never entered full screen") }
            finish(report, to: directory, ok: ok)
        }
    }

    /// Where the window actually is, and where our content sits inside it.
    ///
    /// The bar is drawn into the content view, so a capture of the content view
    /// cannot show a gap that is *above* or *beside* it. This is how a strip of
    /// window chrome between the screen edge and the bar would show up.
    private static func geometry(of window: NSWindow, called step: String) -> String {
        let screen = window.screen ?? NSScreen.main
        let content = window.contentView
        let inWindow = content.map { $0.convert($0.bounds, to: nil) } ?? .zero
        var lines = [
            "\(step): fullScreen=\(window.styleMask.contains(.fullScreen))",
            "  screen frame      \(short(screen?.frame ?? .zero))",
            "  screen visible    \(short(screen?.visibleFrame ?? .zero))",
            "  window frame      \(short(window.frame))",
            "  content in window \(short(inWindow))",
            "  contentLayoutRect \(short(window.contentLayoutRect))"
        ]
        if let insets = content?.safeAreaInsets {
            lines.append("  safe area insets  top \(Int(insets.top)) left \(Int(insets.left)) "
                + "bottom \(Int(insets.bottom)) right \(Int(insets.right))")
        }
        if let screen = screen {
            lines.append("  screen safe area  top \(Int(screen.safeAreaInsets.top)) "
                + "left \(Int(screen.safeAreaInsets.left)) right \(Int(screen.safeAreaInsets.right))")
            // The gap the complaint is about, if there is one: how far our
            // content starts from the top-left of the screen.
            let origin = window.convertPoint(toScreen: CGPoint(x: inWindow.minX, y: inWindow.maxY))
            lines.append("  content top-left  \(Int(origin.x - screen.frame.minX))pt from the left, "
                + "\(Int(screen.frame.maxY - origin.y))pt from the top")
        }
        return lines.joined(separator: "\n")
    }

    private static func short(_ rect: CGRect) -> String {
        "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))×\(Int(rect.height))"
    }

    private static func finish(_ report: [String], to directory: String, ok: Bool) {
        let body = (report + [ok ? "CHROMEPROBE OK" : "CHROMEPROBE FAILED"]).joined(separator: "\n") + "\n"
        try? body.write(toFile: directory + "/report.txt", atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    static func run(shots: String?) {
        let store = MeshvyStore.shared
        let recorder = Recorder()

        // Sized to fit the display: a window whose minimum content size is wider
        // than the screen cannot go full screen at all.
        let fits = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 860)
        let window = NSWindow(
            contentRect: fits.insetBy(dx: 40, dy: 40),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(
            rootView: RootView(store: store)
                // The same floor the real scene sets.
                .frame(minWidth: 1040, minHeight: 640)
        )
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if let shots {
            try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        }

        Task { @MainActor in
            await settle(within: 5) { !store.isIndexing }
            recorder.record(window)

            let windowed = measure(window, to: shots, named: "windowed")
            print("windowed:       \(describe(recorder.last))  first control at \(Int(windowed))pt")

            // Pass 2. Hiding the buttons is exactly what full screen does to
            // them, and it is the clause the bar keys off, so the gutter can be
            // checked without the OS's cooperation. The frame nudge is what
            // provokes the relayout notification.
            setButtons(hidden: true, in: window)
            window.setFrame(window.frame.insetBy(dx: 1, dy: 1), display: true)
            await settle { !WindowChrome.shared.trafficLightsVisible }
            recorder.record(window)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            let hidden = measure(window, to: shots, named: "lights-hidden")
            print("lights hidden:  \(describe(recorder.last))  first control at \(Int(hidden))pt")

            setButtons(hidden: false, in: window)
            window.setFrame(window.frame.insetBy(dx: -1, dy: -1), display: true)
            await settle { WindowChrome.shared.trafficLightsVisible }
            recorder.record(window)
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            let restored = measure(window, to: shots, named: "restored")
            print("restored:       \(describe(recorder.last))  first control at \(Int(restored))pt")

            // Pass 3. A sheet takes the key window; the bar must not read its
            // lack of traffic lights as a reason to give up the gutter.
            let sheet = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            // Not the `await` form: that one returns when the sheet *ends*,
            // which is after this function would have dismissed it.
            window.beginSheet(sheet, completionHandler: nil)
            try? await Task.sleep(for: .milliseconds(500))
            WindowChrome.shared.refresh()
            try? await Task.sleep(for: .milliseconds(300))
            window.contentView?.layoutSubtreeIfNeeded()
            let sheeted = measure(window, to: shots, named: "sheet")
            print("sheet up:       " + describe(WindowChrome.shared.trafficLightsVisible)
                + "  first control at \(Int(sheeted))pt")
            window.endSheet(sheet)
            try? await Task.sleep(for: .milliseconds(400))

            // Pass 4. Observation only.
            window.toggleFullScreen(nil)
            await settle(within: 6) {
                recorder.record(window)
                return recorder.sawFullScreenHidden
            }
            print("""
            full screen:    \(recorder.sawFullScreenHidden
                ? "reported hidden while the style mask said full screen"
                : "never entered — the app was not frontmost")
            """)
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            await settle(within: 6) { !window.styleMask.contains(.fullScreen) }

            for line in recorder.trail { print("  \(line)") }
            window.close()

            // The lights run to x=69, so the first control has to clear them…
            let keptGutter = windowed >= 70 && restored >= 70 && sheeted >= 70
            // …and give the space back when they are not there.
            let droppedGutter = hidden > 0 && hidden <= 24

            guard keptGutter, droppedGutter else {
                print(
                    "CHROMETEST FAILED: keptGutter=\(keptGutter) droppedGutter=\(droppedGutter)"
                        + "  (windowed \(Int(windowed))pt, hidden \(Int(hidden))pt,"
                        + " sheet \(Int(sheeted))pt, restored \(Int(restored))pt)"
                )
                exit(1)
            }
            print("CHROMETEST OK")
            exit(0)
        }
    }

    private static func setButtons(hidden: Bool, in window: NSWindow) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    /// Where the leading edge of the bar's first control actually is, in points
    /// from the window's left edge.
    ///
    /// Measured off the rendered window: SwiftUI draws the bar into one layer,
    /// so there is no `NSView` to ask, and the pixels are what the person is
    /// looking at anyway. The bar is a flat fill, so the first column that
    /// differs from it is the first control — or 0 if the bar is empty.
    @discardableResult
    static func measure(_ window: NSWindow, to directory: String?, named name: String) -> CGFloat {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return 0 }
        content.cacheDisplay(in: content.bounds, to: rep)

        let density = CGFloat(rep.pixelsWide) / max(content.bounds.width, 1)
        if let directory {
            write(rep, to: directory + "/\(name).png")
            // The frame view is the whole window — title bar included — so a
            // strip of chrome above or beside the bar shows up here and not in
            // the capture above.
            if let frameView = content.superview,
               let whole = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: whole)
                write(whole, to: directory + "/\(name)-window.png")
                let band = CGRect(x: 0, y: 0, width: min(CGFloat(whole.pixelsWide), 620 * density),
                                  height: min(CGFloat(whole.pixelsHigh), 72 * density))
                if let cropped = whole.cgImage?.cropping(to: band) {
                    write(NSBitmapImageRep(cgImage: cropped), to: directory + "/\(name)-window-corner.png")
                }
            }
            // The corner is the thing being argued about, and it is a few
            // pixels of a four-megapixel shot otherwise.
            let corner = CGRect(x: 0, y: 0, width: 620 * density, height: 48 * density)
            if let cropped = rep.cgImage?.cropping(to: corner) {
                write(NSBitmapImageRep(cgImage: cropped), to: directory + "/\(name)-corner.png")
            }
        }

        let barRows = Int(48 * density)
        guard let background = rep.colorAt(x: 4, y: barRows / 2) else { return 0 }
        for column in 0..<rep.pixelsWide {
            for row in stride(from: 4, to: max(barRows - 4, 5), by: 2) {
                guard let pixel = rep.colorAt(x: column, y: row) else { continue }
                if differs(pixel, background) { return CGFloat(column) / density }
            }
        }
        return 0
    }

    private static func write(_ rep: NSBitmapImageRep, to path: String) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Enough of a difference to be a glyph rather than antialiasing.
    private static func differs(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let left = a.usingColorSpace(.deviceRGB), let right = b.usingColorSpace(.deviceRGB) else {
            return false
        }
        let delta = abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
        return delta > 0.12
    }

    private static func describe(_ visible: Bool?) -> String {
        switch visible {
        case true: return "lights shown "
        case false: return "lights hidden"
        case nil: return "nothing said "
        }
    }

    private static func settle(
        within seconds: Double = 8, until condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Follows `WindowChrome` — the same value the bar reads — rather than a
    /// callback of its own, so the harness is watching the shipped path.
    @MainActor
    final class Recorder {
        private(set) var trail: [String] = []
        private(set) var last: Bool?
        /// True once the chrome has said the lights are gone while the window's
        /// style mask said full screen: the state the gap used to survive.
        private(set) var sawFullScreenHidden = false

        func record(_ window: NSWindow) {
            let visible = WindowChrome.shared.trafficLightsVisible
            let isFullScreen = window.styleMask.contains(.fullScreen)
            if !visible, isFullScreen { sawFullScreenHidden = true }
            guard visible != last else { return }
            last = visible
            trail.append((visible ? "lights shown " : "lights hidden") + "  fullScreen=\(isFullScreen)")
        }
    }
}
