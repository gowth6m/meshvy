import AppKit
import SwiftUI

@main
struct ForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ForgeStore()

    var body: some Scene {
        WindowGroup("Forge") {
            RootView(store: store)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1560, height: 960)
        .commands { ForgeCommands(store: store) }
    }
}

struct ForgeCommands: Commands {
    var store: ForgeStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace…") {
                NotificationCenter.default.post(name: .forgeNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New LinkedWorktree…") {
                NotificationCenter.default.post(name: .forgeNewLink, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Add Repositories…") {
                NotificationCenter.default.post(name: .forgeAddRepos, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Launch Agent…") {
                NotificationCenter.default.post(name: .forgeLaunchAgent, object: nil)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
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
            Button("Group by LinkedWorktree or Repository") {
                store.grouping = store.grouping == .link ? .repo : .link
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Invert Scroll Direction") { store.invertScroll.toggle() }
            Button("Show Ended Sessions") { store.showEndedSessions.toggle() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .forgeToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .forgeToggleInspector, object: nil)
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
                NotificationCenter.default.post(name: .forgeFocusSearch, object: nil)
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

        if CommandLine.arguments.contains("--perftest") {
            PerfTest.run()
        } else if CommandLine.arguments.contains("--launchtest") {
            LaunchTest.run()
        } else if let repos = SelfTest.request(arguments: CommandLine.arguments) {
            SelfTest.run(repoPaths: repos, keep: CommandLine.arguments.contains("--keep"))
        } else if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            Snapshot.run(request)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
