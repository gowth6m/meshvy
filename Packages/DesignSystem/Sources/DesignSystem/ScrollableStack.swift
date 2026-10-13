import SwiftUI

/// A scrolling column that degrades to a plain link when rendering offscreen.
///
/// `ImageRenderer` never materialises `ScrollView` content, so every panel built
/// on one comes out blank in a `--snapshot`. Swapping the container keeps those
/// renders faithful without changing anything about the shipped behaviour.
public struct ScrollableStack<Content: View>: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    public var alignment: HorizontalAlignment = .center
    @ViewBuilder public var content: Content

    public init(
        alignment: HorizontalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.content = content()
    }

    public var body: some View {
        if isSnapshot {
            // GeometryReader absorbs the proposal instead of letting the link's
            // ideal height push the surrounding layout around.
            GeometryReader { proxy in
                VStack(alignment: alignment, spacing: 0) {
                    content
                }
                // Content wider than the panel — a diff, which does not wrap —
                // has to keep its leading edge, or the clip takes the gutter
                // off the left and the line numbers with it.
                .frame(width: proxy.size.width, alignment: frameAlignment)
            }
            .clipped()
        } else {
            ScrollView { content }
        }
    }

    private var frameAlignment: Alignment {
        if alignment == .leading { return .topLeading }
        if alignment == .trailing { return .topTrailing }
        return .top
    }
}

private struct MeshvySnapshotModeKey: EnvironmentKey {
    public static let defaultValue = false
}

extension EnvironmentValues {
    public var meshvySnapshotMode: Bool {
        get { self[MeshvySnapshotModeKey.self] }
        set { self[MeshvySnapshotModeKey.self] = newValue }
    }
}

/// A text field that becomes plain text when rendered offscreen.
///
/// `ImageRenderer` cannot draw AppKit-backed controls — a `TextField` comes out
/// as a solid yellow block — so a `--snapshot` would show broken chrome. The
/// live app always gets the real control.
public struct SnapshotSafeField: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    public var placeholder: String
    @Binding public var text: String
    /// Panels are a fixed size; a field on a card has to follow the canvas zoom
    /// like everything else on it, or it spills over the node at low zoom.
    public var font: Font = Theme.ui(12)

    public init(
        placeholder: String,
        text: Binding<String>,
        font: Font = Theme.ui(12)
    ) {
        self.placeholder = placeholder
        self._text = text
        self.font = font
    }

    public var body: some View {
        if isSnapshot {
            Text(text.isEmpty ? placeholder : text)
                .font(font)
                .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// A menu that becomes its own label when rendered offscreen, for the same
/// reason as `SnapshotSafeField`.
public struct SnapshotSafeMenu<Label: View, Content: View>: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    @ViewBuilder public var content: Content
    @ViewBuilder public var label: Label

    public init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        if isSnapshot {
            label
        } else {
            Menu { content } label: { label }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}
