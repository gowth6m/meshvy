import SwiftUI

/// Scales a design-time dimension for the current zoom. The canvas renders in
/// screen space rather than using `.scaleEffect`, so text stays crisp at any
/// zoom instead of being rasterised once and stretched.
struct Zoom {
    let scale: CGFloat
    func s(_ value: CGFloat) -> CGFloat { value * scale }
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.ui(max(1, size * scale), weight)
    }
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Theme.mono(max(1, size * scale), weight)
    }
}

/// Small rounded label used for branches, models and paths.
struct Pill: View {
    var text: String
    var icon: String?
    var tint: Color = Theme.textSecondary
    var zoom: Zoom

    var body: some View {
        HStack(spacing: zoom.s(3)) {
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
        .padding(.horizontal, zoom.s(5))
        .padding(.vertical, zoom.s(2))
        .background(
            RoundedRectangle(cornerRadius: zoom.s(4), style: .continuous)
                .fill(tint.opacity(0.11))
        )
        .overlay(
            RoundedRectangle(cornerRadius: zoom.s(4), style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: max(0.5, zoom.s(0.5)))
        )
    }
}

/// Status indicator. Pulses only while a session is actually working, so a glance
/// at the board tells you where the activity is.
struct StatusDot: View {
    var status: SessionStatus
    var zoom: Zoom
    @State private var pulsing = false

    private var color: Color {
        switch status {
        case .busy: return Theme.busy
        case .idle: return Theme.idle
        case .ended: return Theme.ended
        }
    }

    var body: some View {
        ZStack {
            if status == .busy {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: zoom.s(16), height: zoom.s(16))
                    .scaleEffect(pulsing ? 1.0 : 0.45)
                    .opacity(pulsing ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle()
                .fill(color)
                .frame(width: zoom.s(7), height: zoom.s(7))
                .overlay(
                    Circle().stroke(Color.white.opacity(status == .ended ? 0 : 0.35), lineWidth: max(0.5, zoom.s(0.6)))
                )
        }
        .frame(width: zoom.s(16), height: zoom.s(16))
        .onAppear { if status == .busy { pulsing = true } }
    }
}

/// Icon + value pair for the dense bottom row of a card.
struct MetaStat: View {
    var icon: String
    var value: String
    var tint: Color = Theme.textTertiary
    var zoom: Zoom

    var body: some View {
        HStack(spacing: zoom.s(2.5)) {
            Image(systemName: icon).font(zoom.font(8.5, .medium))
            Text(value).font(zoom.font(9.5, .medium))
        }
        .foregroundStyle(tint)
    }
}

/// Toolbar-style button that matches the dark chrome.
struct ChromeButton: View {
    var icon: String
    var label: String?
    var isActive: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
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
                    .fill(isActive ? Theme.accent.opacity(0.14) : (hovering ? Color.white.opacity(0.07) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label ?? icon)
    }
}

enum Format {
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 86_400 * 7 { return "\(Int(seconds / 86_400))d ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = seconds < 86_400 * 330 ? "d MMM" : "MMM yyyy"
        return formatter.string(from: date)
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    static func compactCount(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 1_000_000 {
            let thousands = Double(value) / 1000
            return thousands < 10
                ? String(format: "%.1fk", thousands)
                : "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    /// `claude-opus-5[1m]` → `Opus 5`, `claude-sonnet-5` → `Sonnet 5`.
    static func model(_ raw: String?) -> String? {
        guard var name = raw, !name.isEmpty else { return nil }
        if name == "<synthetic>" { return nil }
        name = name.replacingOccurrences(of: "claude-", with: "")
        name = name.replacingOccurrences(of: "us.anthropic.", with: "")
        if let bracket = name.firstIndex(of: "[") { name = String(name[name.startIndex..<bracket]) }
        // Drop trailing date stamps like `-20251001`.
        let parts = name.split(separator: "-").filter { !($0.count == 8 && Int($0) != nil) }
        guard let first = parts.first else { return nil }
        let family = String(first).capitalized
        // Version segments are split on hyphens upstream (`haiku-4-5`), so numeric
        // tails rejoin with dots and anything else stays spaced.
        let rest = parts.dropFirst()
        let version = rest.prefix { Int($0) != nil }.joined(separator: ".")
        let trailing = rest.drop { Int($0) != nil }.joined(separator: " ")
        return [family, version.isEmpty ? nil : version, trailing.isEmpty ? nil : trailing]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
