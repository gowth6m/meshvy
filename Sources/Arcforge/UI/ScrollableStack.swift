import SwiftUI

/// A scrolling column that degrades to a plain link when rendering offscreen.
///
/// `ImageRenderer` never materialises `ScrollView` content, so every panel built
/// on one comes out blank in a `--snapshot`. Swapping the container keeps those
/// renders faithful without changing anything about the shipped behaviour.
struct ScrollableStack<Content: View>: View {
    @Environment(\.arcforgeSnapshotMode) private var isSnapshot
    var alignment: HorizontalAlignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        if isSnapshot {
            // GeometryReader absorbs the proposal instead of letting the link's
            // ideal height push the surrounding layout around.
            GeometryReader { proxy in
                VStack(alignment: alignment, spacing: 0) {
                    content
                }
                .frame(width: proxy.size.width, alignment: .top)
            }
            .clipped()
        } else {
            ScrollView { content }
        }
    }
}

private struct ArcforgeSnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var arcforgeSnapshotMode: Bool {
        get { self[ArcforgeSnapshotModeKey.self] }
        set { self[ArcforgeSnapshotModeKey.self] = newValue }
    }
}
