import SwiftUI

/// The list of changed files for one checkout.
struct ChangesList: View {
    var changes: [FileChange]
    var selected: FileChange?
    var onSelect: (FileChange) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(changes) { change in
                row(change)
            }
        }
    }

    private func row(_ change: FileChange) -> some View {
        let isSelected = selected?.path == change.path
        return Button { onSelect(change) } label: {
            HStack(spacing: 7) {
                Text(change.kind.letter)
                    .font(Theme.mono(9, .heavy))
                    .foregroundStyle(tint(change.kind))
                    .frame(width: 11)

                HStack(spacing: 0) {
                    if !change.directory.isEmpty {
                        Text(change.directory + "/")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(change.name)
                        .font(Theme.mono(10.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if change.additions > 0 {
                    Text("+\(change.additions)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.clean)
                }
                if change.deletions > 0 {
                    Text("−\(change.deletions)")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.dirty)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.15) : SwiftUI.Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tint(_ kind: FileChange.Kind) -> SwiftUI.Color {
        switch kind {
        case .added, .untracked: return Theme.clean
        case .deleted: return Theme.dirty
        case .renamed: return Theme.branch
        case .modified: return Theme.accent
        }
    }
}

/// A unified diff, rendered line by line with both line numbers.
///
/// Horizontal scrolling is deliberate: wrapping code makes a diff much harder to
/// read, and the inspector can be dragged wider when you need more room.
struct DiffBody: View {
    var diff: FileDiff
    @Environment(\.meshvySnapshotMode) private var isSnapshot

    var body: some View {
        if diff.isBinary {
            note("Binary file — nothing to show.")
        } else if diff.isEmpty {
            note("No changes against HEAD.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // `ImageRenderer` never materialises ScrollView content, so a
                // snapshot shows the lines directly instead of a blank pane.
                if isSnapshot {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.prefix(26))) { line in
                            row(line)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(diff.lines) { line in
                                row(line)
                            }
                        }
                    }
                }
                if diff.truncated {
                    note("Diff is long — showing the first \(DiffParser.maxLines) lines.")
                }
            }
        }
    }

    private func row(_ line: FileDiff.Line) -> some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 7)
            Text(prefix(line.kind))
                .frame(width: 9, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(foreground(line.kind))
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .textSelection(.enabled)
    }

    private func prefix(_ kind: FileDiff.Line.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func foreground(_ kind: FileDiff.Line.Kind) -> SwiftUI.Color {
        switch kind {
        case .added: return Theme.clean
        case .removed: return Theme.dirty
        case .hunk: return Theme.branch
        case .meta: return Theme.textTertiary
        case .context: return Theme.textSecondary
        }
    }

    private func background(_ kind: FileDiff.Line.Kind) -> SwiftUI.Color {
        switch kind {
        case .added: return Theme.clean.opacity(0.09)
        case .removed: return Theme.dirty.opacity(0.09)
        case .hunk: return SwiftUI.Color.white.opacity(0.045)
        default: return .clear
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(10.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.vertical, 6)
    }
}
