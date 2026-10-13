import AppKit
import SwiftUI

/// One entry in a node's working directory.
struct FileEntry: Identifiable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var id: String { path }
}

/// What a node's working directory holds, and whichever file you pick out of
/// it — the counterpart to the changed-file list, for the files an agent has
/// *not* touched yet.
///
/// A repository's own panel answers "what changed". This answers "what is
/// there", which is the question you have before an agent has done anything,
/// and the one the changed list cannot answer by construction.
struct FilesBrowser: View {
    var root: String
    var onOpenInEditor: (String) -> Void

    @State private var selected: String?

    var body: some View {
        VSplit(
            top: { FilesTree(root: root, selected: $selected) },
            bottom: { preview }
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let selected {
            FilePreview(path: selected, onOpenInEditor: onOpenInEditor, onClose: { self.selected = nil })
                .id(selected)
        } else {
            Text("Select a file to read it")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - The tree

/// The directory, as a tree you can open.
///
/// Lazy, and flattened to one list before it is drawn. A directory is read the
/// first time it is opened and then kept, so a tree with a `node_modules` or a
/// `.build` in it costs nothing until it is asked for, and re-rendering the
/// panel does not re-stat the disk.
struct FilesTree: View {
    var root: String
    @Binding var selected: String?

    @State private var expanded: Set<String> = []
    @State private var children: [String: [FileEntry]] = [:]

    var body: some View {
        ScrollableStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 1) {
                let rows = visibleRows
                if rows.isEmpty {
                    Text(children[root] == nil ? "Reading…" : "This folder is empty")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rows, id: \.entry.id) { row in
                        self.row(row.entry, depth: row.depth)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { load(root) }
    }

    /// Every row currently on screen, with how deep it sits. Recursion happens
    /// here rather than in the view tree: a view that nests itself has no
    /// finite type, and a flat `ForEach` scrolls better besides.
    private var visibleRows: [(entry: FileEntry, depth: Int)] {
        var rows: [(FileEntry, Int)] = []
        func walk(_ path: String, _ depth: Int) {
            for entry in children[path] ?? [] {
                rows.append((entry, depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    walk(entry.path, depth + 1)
                }
            }
        }
        walk(root, 0)
        return rows
    }

    private func row(_ entry: FileEntry, depth: Int) -> some View {
        let isExpanded = expanded.contains(entry.path)
        let isSelected = selected == entry.path
        return Button {
            if entry.isDirectory {
                if isExpanded {
                    expanded.remove(entry.path)
                } else {
                    expanded.insert(entry.path)
                    load(entry.path)
                }
            } else {
                selected = entry.path
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.ui(7, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 8)
                    .opacity(entry.isDirectory ? 1 : 0)
                Image(systemName: FilesTree.icon(for: entry))
                    .font(Theme.ui(9.5))
                    .foregroundStyle(entry.isDirectory ? Theme.worktree : Theme.textTertiary)
                    .frame(width: 12)
                Text(entry.name)
                    .font(Theme.mono(10.5, entry.isDirectory ? .medium : .regular))
                    .foregroundStyle(entry.isDirectory ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
        }
    }

    private func load(_ path: String) {
        guard children[path] == nil else { return }
        children[path] = FilesTree.read(path)
    }

    /// One directory, directories first and then files, each run in the order
    /// a person reads them rather than the order the filesystem returns them.
    static func read(_ path: String) -> [FileEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return urls.compactMap { url -> FileEntry? in
            let name = url.lastPathComponent
            // The checkout's plumbing, not part of the checkout.
            guard name != ".git" else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileEntry(path: url.path, name: name, isDirectory: isDirectory)
        }
        .sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
    }

    static func icon(for entry: FileEntry) -> String {
        guard !entry.isDirectory else { return "folder" }
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "resolved": return "curlybraces"
        case "sh", "bash", "zsh": return "terminal"
        case "png", "jpg", "jpeg", "gif", "svg", "icns", "pdf": return "photo"
        case "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - Reading one file

/// The file itself. Read off the main thread, capped, and refused outright when
/// it is not text — a panel that printed a PNG as mojibake would be worse than
/// one that says it cannot.
private struct FilePreview: View {
    @Environment(\.meshvySnapshotMode) private var isSnapshot
    var path: String
    var onOpenInEditor: (String) -> Void
    var onClose: () -> Void

    @State private var contents: String?
    @State private var problem: String?

    /// What to draw. `ImageRenderer` never awaits a `.task`, so a documentation
    /// shot would catch the spinner every time; offscreen it reads inline
    /// instead. The live app never touches the disk on this thread.
    private var resolved: Outcome? {
        if let problem { return .refused(problem) }
        if let contents { return .text(contents) }
        return isSnapshot ? FilePreview.read(path) : nil
    }

    private nonisolated static let limit = 512 * 1024

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(Theme.mono(10.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                ChromeButton(icon: "chevron.left.forwardslash.chevron.right") { onOpenInEditor(path) }
                ChromeButton(icon: "xmark", action: onClose)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface)
            Divider().overlay(Theme.hairline)

            switch resolved {
            case .refused(let why):
                Text(why)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let body):
                ScrollableStack(alignment: .leading) {
                    Text(body)
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            case nil:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: path) {
            let outcome = await Task.detached(priority: .userInitiated) {
                FilePreview.read(path)
            }.value
            switch outcome {
            case .text(let body): contents = body; problem = nil
            case .refused(let why): contents = nil; problem = why
            }
        }
    }

    private enum Outcome {
        case text(String)
        case refused(String)
    }

    private nonisolated static func read(_ path: String) -> Outcome {
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > limit {
            return .refused("\(Format.bytes(Int64(size))) — too big to show here. Open it in your editor.")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .refused("Could not read this file.")
        }
        // A NUL byte early on is the usual tell, and anything that is not UTF-8
        // would come out as noise regardless.
        if data.prefix(8192).contains(0) {
            return .refused("Binary file — \(Format.bytes(Int64(size))).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .refused("Not UTF-8 text — \(Format.bytes(Int64(size))).")
        }
        return .text(text)
    }
}
