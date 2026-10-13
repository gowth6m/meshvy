import AppKit
import SwiftUI

/// Which modal flow is open. One enum keeps the presentation logic in `RootView`
/// to a single `.sheet`.
public enum MeshvySheet: Identifiable {
    case newWorkspace
    case addRepos
    case update

    public var id: String {
        switch self {
        case .newWorkspace: return "newWorkspace"
        case .addRepos: return "addRepos"
        case .update: return "update"
        }
    }
}

// MARK: - Shared chrome

public struct SheetFrame<Content: View, Footer: View>: View {
    public var title: String
    public var subtitle: String?
    @ViewBuilder public var content: Content
    @ViewBuilder public var footer: Footer

    public init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.ui(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider().overlay(Theme.hairline)

            ScrollView { content.padding(16) }
                .frame(maxHeight: 460)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 8) { footer }
                .padding(14)
        }
        .frame(width: 540)
        .background(Theme.surfaceSunken)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

public struct FormField<Content: View>: View {
    public var label: String
    public var hint: String?
    @ViewBuilder public var content: Content

    public init(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.hint = hint
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(Theme.ui(9.5, .heavy))
                .tracking(0.7)
                .foregroundStyle(Theme.textTertiary)
            content
            if let hint {
                Text(hint)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

public struct BoxedField: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.ui(12))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 1)
            )
    }
}

extension View {
    public func boxedField() -> some View { modifier(BoxedField()) }
}

public struct PrimaryButton: View {
    public var title: String
    public var isEnabled: Bool = true
    public var action: () -> Void

    public init(
        title: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(isEnabled ? Theme.onAccent : Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isEnabled ? Theme.accent : Theme.fill)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .keyboardShortcut(.defaultAction)
    }
}

public struct SecondaryButton: View {
    public var title: String
    public var action: () -> Void

    public init(
        title: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Repository picker

// MARK: - New workspace

// MARK: - Add repositories
