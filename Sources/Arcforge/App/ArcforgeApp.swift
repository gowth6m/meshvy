import AppKit
import SwiftUI

@main
struct ArcforgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ArcforgeStore()

    var body: some Scene {
        WindowGroup("Arcforge") {
            RootView(store: store)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1560, height: 960)
        .commands { ArcforgeCommands(store: store) }
    }
}

struct ArcforgeCommands: Commands {
    var store: ArcforgeStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace…") {
                NotificationCenter.default.post(name: .arcforgeNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Orchestrator Terminal") {
                NotificationCenter.default.post(name: .arcforgeOpenOrchestrator, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Open Shell") {
                NotificationCenter.default.post(name: .arcforgeOpenShell, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Add Repositories…") {
                NotificationCenter.default.post(name: .arcforgeAddRepos, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("View") {
            Button("Fit to Content") { store.fit() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Zoom In") { store.zoom(by: 1.25) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { store.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { store.zoomToActualSize() }
                .keyboardShortcut("1", modifiers: .command)
            Divider()
            Button("Show Ended Sessions") { store.showEndedSessions.toggle() }
            Button("Invert Scroll Direction") { store.invertScroll.toggle() }
            Button("Show Ended Sessions") { store.showEndedSessions.toggle() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .arcforgeToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .arcforgeToggleInspector, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        CommandMenu("Board") {
            Button("Refresh Everything") { store.refreshAll() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Refresh Git Status") { store.refreshGitStatus() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Find…") {
                NotificationCenter.default.post(name: .arcforgeFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Focus Search Matches") { store.focusMatches() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Reset Auto-Layout") { store.resetLayout() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The canvas palette is tuned for a dark surface; keep it consistent
        // regardless of the system setting.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let arguments = CommandLine.arguments
        if let path = DiffTest.path(arguments: arguments) {
            DiffTest.run(path: path)
        } else if arguments.contains("--perftest") {
            PerfTest.run()
        } else if arguments.contains("--launchtest") {
            LaunchTest.run()
        } else if let repos = SelfTest.repoPaths(arguments: arguments) {
            SelfTest.run(repoPaths: repos, keep: arguments.contains("--keep"))
        } else if let request = SnapshotRequest(arguments: arguments) {
            Snapshot.run(request)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
