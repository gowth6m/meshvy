import AppKit
import SwiftUI

/// Offscreen renderer for development: `Forge --snapshot out.png`.
///
/// Renders the real view tree against the real `~/.claude` data with
/// `ImageRenderer`, so the UI can be inspected (and diffed) from a terminal
/// without a visible window or screen-recording permission.
struct SnapshotRequest {
    var output: URL
    var size: CGSize
    var waitSeconds: Double
    var selectNewestSession: Bool
    var zoomToFit: Bool
    /// Explicit zoom, centred on the selection. Overrides fit-to-content.
    var zoom: Double?

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return nil }
        output = URL(fileURLWithPath: arguments[flag + 1])

        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let width = value("--width").flatMap(Double.init) ?? 1560
        let height = value("--height").flatMap(Double.init) ?? 960
        size = CGSize(width: width, height: height)
        waitSeconds = value("--wait").flatMap(Double.init) ?? 6
        selectNewestSession = !arguments.contains("--no-select")
        zoom = value("--zoom").flatMap(Double.init)
        zoomToFit = zoom == nil && !arguments.contains("--no-fit")
    }
}

@MainActor
enum Snapshot {
    static func run(_ request: SnapshotRequest) {
        let store = ForgeStore()

        // The canvas normally learns its size from a GeometryReader; there is no
        // window here, so derive it from the requested image size.
        let chromeHeight: CGFloat = 46 + 26 + 2
        let panels: CGFloat = 258 + 430 + 2
        store.viewport.size = CGSize(
            width: max(200, request.size.width - panels),
            height: max(200, request.size.height - chromeHeight)
        )
        store.bootstrap()

        let deadline = Date().addingTimeInterval(request.waitSeconds)
        poll(store: store, request: request, deadline: deadline)
    }

    /// Waits for indexing and git discovery, then renders. Polls rather than
    /// awaits so the main run loop keeps servicing the store's own callbacks.
    private static func poll(store: ForgeStore, request: SnapshotRequest, deadline: Date) {
        let settled = !store.isIndexing && !store.isLoadingGit && !store.graph.nodes.isEmpty
        let expired = Date() >= deadline

        guard settled || expired else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { poll(store: store, request: request, deadline: deadline) }
            }
            return
        }

        if request.selectNewestSession, store.selection == nil {
            let newest = store.graph.nodes
                .filter { if case .session = $0.kind { return true } else { return false } }
                .max { $0.sortDate < $1.sortDate }
            if let newest { store.select(newest.id) }
        }
        if let zoom = request.zoom {
            store.viewport.scale = CGFloat(zoom)
            if let selected = store.selection, let node = store.graph.node(selected) {
                store.viewport.center = node.frame.center
            } else if let rect = store.graph.contentRect {
                store.viewport.center = rect.center
            }
        } else if request.zoomToFit {
            store.fit()
        }

        // One more short wait so the transcript load and a layout pass land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            MainActor.assumeIsolated { render(store: store, request: request) }
        }
    }

    private static func render(store: ForgeStore, request: SnapshotRequest) {
        let view = RootView(store: store)
            .frame(width: request.size.width, height: request.size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.forgeSnapshotMode, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: ImageRenderer produced no image\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: request.output)
            print("snapshot: wrote \(request.output.path) (\(image.width)×\(image.height))")
            print("snapshot: \(store.statusLine)")
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
