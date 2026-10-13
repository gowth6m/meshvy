import MeshvyModels
import SwiftUI

/// Small rounded label used for branches, models and paths.
public struct Pill: View {
    public var text: String
    public var icon: String?
    public var tint: Color = Theme.textSecondary
    public var zoom: Zoom

    public init(text: String, icon: String? = nil, tint: Color = Theme.textSecondary, zoom: Zoom) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.zoom = zoom
    }

    public var body: some View {
        HStack(spacing: zoom.t(3)) {
            if let icon {
                Image(systemName: icon)
                    .font(zoom.font(8, .semibold))
            }
            Text(text)
                .font(zoom.mono(9.5, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, zoom.t(5))
        .padding(.vertical, zoom.t(2))
        .background(
            RoundedRectangle(cornerRadius: zoom.t(4), style: .continuous)
                .fill(tint.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: zoom.t(4), style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: max(0.5, zoom.t(0.5)))
        )
    }
}

/// Status indicator. Pulses only while a session is actually working, so a glance
/// at the board tells you where the activity is.
public struct StatusDot: View {
    public var status: SessionStatus
    public var zoom: Zoom

    public init(status: SessionStatus, zoom: Zoom) {
        self.status = status
        self.zoom = zoom
    }
    @State private var pulsing = false

    private var color: Color {
        switch status {
        case .busy: return Theme.busy
        case .idle: return Theme.idle
        case .ended: return Theme.ended
        }
    }

    public var body: some View {
        ZStack {
            if status == .busy {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: zoom.t(16), height: zoom.t(16))
                    .scaleEffect(pulsing ? 1.0 : 0.45)
                    .opacity(pulsing ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle()
                .fill(color)
                .frame(width: zoom.t(7), height: zoom.t(7))
                .overlay(
                    Circle().stroke(Theme.textPrimary.opacity(status == .ended ? 0 : 0.3), lineWidth: max(0.5, zoom.t(0.6)))
                )
        }
        .frame(width: zoom.t(16), height: zoom.t(16))
        .onAppear { if status == .busy { pulsing = true } }
    }
}

/// Icon + value pair for the dense bottom row of a card.
public struct MetaStat: View {
    public var icon: String
    public var value: String
    public var tint: Color = Theme.textTertiary
    public var zoom: Zoom

    public init(icon: String, value: String, tint: Color = Theme.textTertiary, zoom: Zoom) {
        self.icon = icon
        self.value = value
        self.tint = tint
        self.zoom = zoom
    }

    public var body: some View {
        HStack(spacing: zoom.t(2.5)) {
            Image(systemName: icon).font(zoom.font(8.5, .medium))
            Text(value).font(zoom.font(9.5, .medium))
        }
        .foregroundStyle(tint)
    }
}

/// Toolbar-style button that matches the dark chrome.
///
/// `help` is the tooltip, and for a button that is only an icon it is the
/// accessibility label too. It is a parameter rather than a `.help` at the call
/// site because the button used to set its own, from the SF Symbol's name —
/// which is how the inspector came to explain its buttons as "xmark",
/// "folder" and "arrow.clockwise", and VoiceOver to read them out that way.
public struct ChromeButton: View {
    public var icon: String
    public var label: String?
    public var help: String?
    public var isActive: Bool = false
    public var action: () -> Void

    public init(
        icon: String,
        label: String? = nil,
        help: String? = nil,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.help = help
        self.isActive = isActive
        self.action = action
    }
    @Environment(\.chromeButtonsBordered) private var bordered
    @State private var hovering = false

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(Theme.ui(11, .semibold))
                if let label { Text(label).font(Theme.ui(11.5, .medium)) }
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, label == nil ? 7 : 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Theme.accent.opacity(0.14) : (hovering ? Theme.fill : restingFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? Theme.accent.opacity(0.35) : restingStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? label ?? "")
        .accessibilityLabel(Text(label ?? help ?? icon))
    }

    /// A toolbar button is found by where it sits; one in a panel, among text
    /// and values, has to look like something you can press before anyone
    /// hovers it.
    private var restingFill: Color { bordered ? Theme.fillSubtle : .clear }
    private var restingStroke: Color { bordered ? Theme.hairline : .clear }
}

private struct ChromeButtonsBorderedKey: EnvironmentKey {
    public static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on a panel so its `ChromeButton`s draw their outline at rest.
    public var chromeButtonsBordered: Bool {
        get { self[ChromeButtonsBorderedKey.self] }
        set { self[ChromeButtonsBorderedKey.self] = newValue }
    }
}
