import SwiftUI

/// Everything behind the interactive cards, drawn in one `Canvas` pass:
/// the dot grid, the edges back to the workspace node, and — when zoomed far
/// out — the cards themselves as plain blocks.
///
/// Collapsing the zoomed-out case into drawing commands is what keeps a board of
/// a few hundred nodes smooth; no SwiftUI view is created for a node you cannot
/// read anyway.
struct CanvasBackdrop: View {
    var graph: CanvasGraph
    var viewport: Viewport
    var selection: NodeID?
    var matching: Set<String>
    var isSearching: Bool

    private var detail: DetailLevel { DetailLevel(scale: viewport.scale) }

    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.canvas))
            drawGrid(&context, size: size)
            drawEdges(&context)
            if detail == .block { drawBlocks(&context) }
        }
    }

    // MARK: Grid

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        let spacing: CGFloat = 40
        let screenSpacing = spacing * viewport.scale
        // Below ~9 px apart the dots read as noise, so fade them out entirely.
        guard screenSpacing > 9 else { return }

        let world = viewport.visibleWorldRect(padding: spacing)
        guard !world.isEmpty else { return }
        // Defence in depth: the dot count is bounded by the visible area, but a
        // bad viewport must never be able to spin this loop.
        let columns = Int(world.width / spacing) + 1
        let rows = Int(world.height / spacing) + 1
        guard columns * rows <= 40_000 else { return }

        let startX = (world.minX / spacing).rounded(.down) * spacing
        let startY = (world.minY / spacing).rounded(.down) * spacing
        let dotSize = max(1, min(1.6, viewport.scale))
        let fade = min(1, (screenSpacing - 9) / 14)

        var minor = Path()
        var major = Path()
        var x = startX
        while x < world.maxX {
            var y = startY
            while y < world.maxY {
                let point = viewport.project(CGPoint(x: x, y: y))
                let rect = CGRect(
                    x: point.x - dotSize / 2, y: point.y - dotSize / 2,
                    width: dotSize, height: dotSize
                )
                let isMajor = x.truncatingRemainder(dividingBy: spacing * 5) == 0
                    && y.truncatingRemainder(dividingBy: spacing * 5) == 0
                if isMajor { major.addEllipse(in: rect.insetBy(dx: -dotSize * 0.25, dy: -dotSize * 0.25)) }
                else { minor.addEllipse(in: rect) }
                y += spacing
            }
            x += spacing
        }
        context.fill(minor, with: .color(Theme.grid.opacity(fade)))
        context.fill(major, with: .color(Theme.gridMajor.opacity(fade)))
    }

    // MARK: Edges

    private func drawEdges(_ context: inout GraphicsContext) {
        guard viewport.scale > 0.12 else { return }
        let visible = viewport.visibleWorldRect()
        var frames: [NodeID: CGRect] = [:]
        for node in graph.nodes { frames[node.id] = node.frame }

        var idle = Path()
        var structural = Path()
        var active = Path()
        var drawn = Path()

        for edge in graph.edges {
            guard let fromFrame = frames[edge.from], let toFrame = frames[edge.to] else { continue }
            guard fromFrame.intersects(visible) || toFrame.intersects(visible) else { continue }

            let start = viewport.project(fromFrame.anchor(towards: toFrame.center))
            let end = viewport.project(toFrame.anchor(towards: fromFrame.center))
            let dx = (end.x - start.x) * 0.5

            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x - dx * 0.9, y: start.y),
                control2: CGPoint(x: end.x + dx * 0.9, y: end.y)
            )
            // A terminal's ownership of a checkout is drawn in the accent so
            // the parent/child shape of the workspace is readable at a glance.
            // Ownership and dispatch edges carry the shape of the workspace, so
            // they are drawn in the brand accent and stay visible even when the
            // far end is idle. Amber is reserved for an agent actually working.
            switch edge.kind {
            case .owns, .dispatched, .watches: structural.addPath(path)
            case .feeds: drawn.addPath(path)
            case .ranIn:
                if edge.isLive { active.addPath(path) } else { idle.addPath(path) }
            }
        }

        context.stroke(
            idle,
            with: .color(Theme.hairlineStrong.opacity(0.75)),
            style: StrokeStyle(lineWidth: max(0.5, 1.1 * viewport.scale), lineCap: .round)
        )
        context.stroke(
            structural,
            with: .color(Theme.accent.opacity(0.6)),
            style: StrokeStyle(lineWidth: max(0.7, 1.8 * viewport.scale), lineCap: .round)
        )
        context.stroke(
            active,
            with: .color(Theme.busy.opacity(0.55)),
            style: StrokeStyle(lineWidth: max(0.7, 1.8 * viewport.scale), lineCap: .round)
        )
        // Dashed, because a link you drew is a claim about the work rather than
        // a fact about the workspace.
        context.stroke(
            drawn,
            with: .color(Theme.sidechain.opacity(0.85)),
            style: StrokeStyle(
                lineWidth: max(0.8, 2.0 * viewport.scale),
                lineCap: .round,
                dash: [max(2, 6 * viewport.scale), max(2, 4 * viewport.scale)]
            )
        )
    }

    // MARK: Zoomed-out node blocks

    private func drawBlocks(_ context: inout GraphicsContext) {
        let visible = viewport.visibleWorldRect()
        for node in graph.nodes where node.frame.intersects(visible) {
            // Workspace and terminal nodes always draw themselves.
            if case .workspace = node.kind { continue }
            if case .terminal = node.kind { continue }
            if case .browser = node.kind { continue }
            let rect = viewport.project(node.frame)
            let corner = max(2, Theme.nodeCorner * viewport.scale)
            let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
            let dimmed = isSearching && !matching.contains(node.id.storageKey)

            let (fill, accent): (SwiftUI.Color, SwiftUI.Color) = {
                switch node.kind {
                case .session(let summary, let status, _):
                    switch status {
                    case .busy: return (Theme.surfaceRaised, Theme.busy)
                    case .idle: return (Theme.surfaceRaised, Theme.idle)
                    case .ended: return (Theme.surface, summary.isSidechain ? Theme.sidechain : Theme.ended)
                    }
                case .terminal, .workspace:
                    // These keep their own live view at every zoom; the block
                    // layer never needs to stand in for one.
                    return (Theme.canvasDeep, Theme.accent)
                case .subAgent(let agent):
                    return (Theme.surface, agent.state.isRunning ? Theme.busy : Theme.clean)
                case .browser:
                    return (Theme.canvasDeep, Theme.branch)
                }
            }()

            context.opacity = dimmed ? 0.2 : 1
            context.fill(path, with: .color(fill))
            // Accent rail, mirroring the full-detail card so the board reads the
            // same at every zoom.
            let rail = CGRect(x: rect.minX, y: rect.minY, width: max(1.5, 3 * viewport.scale), height: rect.height)
            context.fill(Path(roundedRect: rail, cornerRadius: corner * 0.5), with: .color(accent))
            context.stroke(
                path,
                with: .color(node.id == selection ? Theme.accent : Theme.hairline),
                lineWidth: node.id == selection ? max(1, 2 * viewport.scale) : 0.6
            )
            context.opacity = 1
        }
    }
}
