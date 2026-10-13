import AppKit
import Foundation
import MeshvyModels

// Shelling out to the editor, the terminal and Finder.
extension MeshvyStore {
    // MARK: - Shell-outs

    public func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// Hands a page to the user's real browser — for the moment a canvas node
    /// is not the right place to be, like signing in or opening devtools.
    public func openInBrowser(_ url: String) {
        guard let normalized = BrowserNode.normalize(url), let target = URL(string: normalized) else { return }
        NSWorkspace.shared.open(target)
    }

    public func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens the uninstaller in Terminal.
    ///
    /// Deliberately not run silently in-process: it hands git worktrees back to
    /// their repositories and can decline to remove checkouts holding unsaved
    /// work, and that conversation belongs in a terminal where it can be read
    /// and answered. The script ships inside the bundle.
    public func runUninstaller() {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/uninstall.sh")
        guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
            show(.init(
                kind: .failure,
                title: "No uninstaller in this build",
                detail: "Run Scripts/uninstall.sh from the repository instead."
            ))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", bundled.path]
        do {
            try process.run()
        } catch {
            show(.init(
                kind: .failure,
                title: "Could not open Terminal",
                detail: "Run this yourself:\n\(bundled.path)"
            ))
        }
    }

    public func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func revealTranscriptFile(_ summary: SessionSummary) {
        NSWorkspace.shared.selectFile(
            summary.fileURL.path,
            inFileViewerRootedAtPath: summary.fileURL.deletingLastPathComponent().path
        )
    }
}
