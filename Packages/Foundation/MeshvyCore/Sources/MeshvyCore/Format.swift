import Foundation

public enum Format {
    public static func relative(_ date: Date) -> String {
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

    public static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    public static func compactCount(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        if value < 1_000_000 {
            let thousands = Double(value) / 1000
            return thousands < 10
                ? String(format: "%.1fk", thousands)
                : "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: value)
    }

    /// `claude-opus-5[1m]` → `Opus 5`, `claude-sonnet-5` → `Sonnet 5`.
    public static func model(_ raw: String?) -> String? {
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
