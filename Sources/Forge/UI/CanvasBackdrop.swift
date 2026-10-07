import SwiftUI

/// Everything behind the interactive cards, drawn in one `Canvas` pass:
/// the dot grid, repository containers, session→worktree edges, and — when
/// zoomed far out — the cards themselves as plain blocks.
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
            drawGroups(&context)
            drawEdges(&context)
            if detail == .block { drawBlocks(&context) }
        }
        .drawingGroup(opaque: true)
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

    // MARK: Groups

    private func drawGroups(_ context: inout GraphicsContext) {
        let visible = viewport.visibleWorldRect()
        for group in graph.groups where group.rect.intersects(visible) {
            let rect = viewport.project(group.rect)
            let style = GroupStyle(kind: group.kind, seed: group.seed)
            let corner = Theme.groupCorner * viewport.scale
            let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)

            context.fill(path, with: .color(Theme.canvasDeep.opacity(0.55)))
            context.fill(path, with: .color(style.tint.opacity(style.fillOpacity)))
            context.stroke(
                path,
                with: .color(style.tint.opacity(style.strokeOpacity)),
                style: StrokeStyle(
                    lineWidth: max(0.6, style.lineWidth * viewport.scale),
                    dash: style.isDashed ? [6 * viewport.scale, 5 * viewport.scale] : []
                )
            )

            guard viewport.scale > 0.1 else { continue }
            let titleSize = max(11, 15 * viewport.scale)
            let titleFont = Theme.ui(titleSize, .bold)
            let baseline = rect.minY - 7
            var cursorX = rect.minX + 2

            // A stack spans several repositories, so it earns a marker that says
            // so even when the board is zoomed too far out to read the lanes.
            if style.badge != nil, viewport.scale > 0.3 {
                let glyphSize = titleSize * 0.92
                context.draw(
                    Text(Image(systemName: style.badge!))
                        .font(Theme.ui(glyphSize, .semibold))
                        .foregroundStyle(style.tint),
                    at: CGPoint(x: cursorX, y: baseline),
                    anchor: .bottomLeading
                )
                cursorX += glyphSize * 1.5
            }

            let available = rect.width - (cursorX - rect.minX)
            guard let (title, titleWidth) = fitted(
                group.title, font: titleFont, maxWidth: available, context: context
            ) else { continue }

            context.draw(
                title.foregroundStyle(style.tint.opacity(0.95)),
                at: CGPoint(x: cursorX, y: baseline),
                anchor: .bottomLeading
            )

            let remaining = available - titleWidth - 12
            guard viewport.scale > 0.35, remaining > 60 else { continue }
            let subtitleFont = Theme.mono(max(9, 10.5 * viewport.scale))
            if let (subtitle, _) = fitted(
                abbreviate(group.subtitle), font: subtitleFont, maxWidth: remaining, context: context
            ) {
                context.draw(
                    subtitle.foregroundStyle(Theme.textTertiary),
                    at: CGPoint(x: cursorX + titleWidth + 12, y: baseline),
                    anchor: .bottomLeading
                )
            }
        }
    }

    /// How a container is drawn, per section kind.
    private struct GroupStyle {
        var tint: Color
        var fillOpacity: Double
        var strokeOpacity: Double
        var lineWidth: CGFloat
        var isDashed: Bool
        var badge: String?

        init(kind: GroupKind, seed: String) {
            switch kind {
            case .stack:
                tint = Theme.repoTint(seed)
                fillOpacity = 0.07
                strokeOpacity = 0.45
                lineWidth = 1.4
                isDashed = false
                badge = "square.stack.3d.up.fill"
            case .main:
                tint = Theme.worktree
                fillOpacity = 0.045
                strokeOpacity = 0.3
                lineWidth = 1
                isDashed = false
                badge = "shippingbox.fill"
            case .repo:
                tint = Theme.repoTint(seed)
                fillOpacity = 0.045
                strokeOpacity = 0.26
                lineWidth = 1
                isDashed = false
                badge = nil
            case .other:
                tint = Theme.textSecondary
                fillOpacity = 0.03
                strokeOpacity = 0.2
                lineWidth = 1
                isDashed = false
                badge = nil
            case .archived:
                tint = Theme.ended
                fillOpacity = 0.025
                strokeOpacity = 0.3
                lineWidth = 1
                isDashed = true
                badge = "archivebox"
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Truncates `string` with an ellipsis until it fits `maxWidth`, returning the
    /// drawable text and its measured width. Nil when even one character will not
    /// fit, in which case the label is skipped rather than overlapping a
    /// neighbouring group.
    private func fitted(
        _ string: String, font: Font, maxWidth: CGFloat, context: GraphicsContext
    ) -> (Text, CGFloat)? {
        guard maxWidth > 8 else { return nil }
        let bounds = CGSize(width: 10_000, height: 200)
        func measure(_ candidate: String) -> CGFloat {
            context.resolve(Text(candidate).font(font)).measure(in: bounds).width
        }

        let full = measure(string)
        if full <= maxWidth { return (Text(string).font(font), full) }

        // Estimate the fitting length from the ratio, then walk down.
        var count = max(1, Int(Double(string.count) * Double(maxWidth / full)))
        while count >= 1 {
            let candidate = String(string.prefix(count)) + "…"
            let width = measure(candidate)
            if width <= maxWidth { return (Text(candidate).font(font), width) }
            count -= 1
        }
        return nil
    }

    // MARK: Edges

    private func drawEdges(_ context: inout GraphicsContext) {
        guard viewport.scale > 0.12 else { return }
        let visible = viewport.visibleWorldRect()
        var frames: [NodeID: CGRect] = [:]
        for node in graph.nodes { frames[node.id] = node.frame }

        var idle = Path()
        var active = Path()

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
            if edge.isLive { active.addPath(path) } else { idle.addPath(path) }
        }

        context.stroke(
            idle,
            with: .color(Theme.hairlineStrong.opacity(0.75)),
            style: StrokeStyle(lineWidth: max(0.5, 1.1 * viewport.scale), lineCap: .round)
        )
        context.stroke(
            active,
            with: .color(Theme.busy.opacity(0.55)),
            style: StrokeStyle(lineWidth: max(0.7, 1.8 * viewport.scale), lineCap: .round)
        )
    }

    // MARK: Zoomed-out node blocks

    private func drawBlocks(_ context: inout GraphicsContext) {
        let visible = viewport.visibleWorldRect()
        for node in graph.nodes where node.frame.intersects(visible) {
            let rect = viewport.project(node.frame)
            let corner = max(2, Theme.nodeCorner * viewport.scale)
            let path = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
            let dimmed = isSearching && !matching.contains(node.id.storageKey)

            let (fill, accent): (Color, Color) = {
                switch node.kind {
                case .session(let summary, let status, _):
                    switch status {
                    case .busy: return (Theme.surfaceRaised, Theme.busy)
                    case .idle: return (Theme.surfaceRaised, Theme.idle)
                    case .ended: return (Theme.surface, summary.isSidechain ? Theme.sidechain : Theme.ended)
                    }
                case .worktree(let worktree):
                    return (Theme.surfaceSunken, worktree.isDirty ? Theme.dirty : Theme.worktree)
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
