import Foundation

/// How the Claude CLI stamps a transcript line.
///
/// Fractional seconds are not optional in `ISO8601DateFormatter`: a formatter
/// without `.withFractionalSeconds` returns nil for every line the CLI writes.
/// Shared because the session indexer and the sub-agent tracker read the same
/// files, and a second formatter that disagreed would silently date half the
/// board differently.
extension ISO8601DateFormatter {
    public static let transcript: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
