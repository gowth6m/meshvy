import AppKit
import AppShell
import AppState
import DesignSystem
import MeshvyModels
import ProcessKit
import SwiftUI

@main
struct MeshvyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = MeshvyStore.shared

    var body: some Scene {
        WindowGroup("Meshvy") {
            RootView(store: store)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1560, height: 960)
        .commands { MeshvyCommands(store: store) }
    }
}

struct MeshvyCommands: Commands {
    var store: MeshvyStore

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NotificationCenter.default.post(name: .meshvyCheckForUpdates, object: nil)
            }
            Divider()
            Button("Uninstall Meshvy…") {
                NotificationCenter.default.post(name: .meshvyUninstall, object: nil)
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Workspace…") {
                NotificationCenter.default.post(name: .meshvyNewWorkspace, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open the Coordinator") {
                NotificationCenter.default.post(name: .meshvyOpenCoordinator, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Open Shell") {
                NotificationCenter.default.post(name: .meshvyOpenShell, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Open Browser") {
                NotificationCenter.default.post(name: .meshvyOpenBrowser, object: nil)
            }
            .keyboardShortcut("b", modifiers: .command)
            Button("Add Repositories…") {
                NotificationCenter.default.post(name: .meshvyAddRepos, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Archive Workspace") {
                NotificationCenter.default.post(name: .meshvyArchiveWorkspace, object: nil)
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
        }

        CommandMenu("Agents") {
            Button("Command Palette…") {
                NotificationCenter.default.post(name: .meshvyPalette, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
            Button("Next Agent Waiting On Me") {
                NotificationCenter.default.post(name: .meshvyNextAgent, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Picker("Permission Mode", selection: Binding(
                get: { store.permissionMode },
                set: { store.selectPermissionMode($0) }
            )) {
                ForEach(PermissionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("Effort", selection: Binding(
                get: { store.agentEffort },
                set: { store.selectEffort($0) }
            )) {
                ForEach(AgentEffort.allCases) { effort in
                    Text(effort.label).tag(effort)
                }
            }
            Picker("Model", selection: Binding(
                get: { store.models.selectedModelID ?? "" },
                set: { store.selectModel($0.isEmpty ? nil : $0) }
            )) {
                ForEach(store.models.models, id: \.key) { model in
                    Text(model.displayName).tag(model.id ?? "")
                }
            }
            Toggle("Notify Me When An Agent Needs Me", isOn: Binding(
                get: { store.notifier.isEnabled },
                set: { store.notifier.isEnabled = $0; store.persistLayout() }
            ))
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
            Button("Zoom to Selection") { store.zoomToSelection() }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            // Toggles rather than buttons, so the menu says which way each one
            // is set instead of leaving you to flip it and look.
            Toggle("Show Ended Sessions", isOn: Binding(
                get: { store.showEndedSessions },
                set: { store.showEndedSessions = $0 }
            ))
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Toggle("Invert Scroll Direction", isOn: Binding(
                get: { store.invertScroll },
                set: { store.invertScroll = $0 }
            ))
            Divider()
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .meshvyToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Inspector") {
                NotificationCenter.default.post(name: .meshvyToggleInspector, object: nil)
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
                NotificationCenter.default.post(name: .meshvyFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Focus Search Matches") { store.focusMatches() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Reset Auto-Layout") { store.resetLayout() }
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                NotificationCenter.default.post(name: .meshvyShortcuts, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
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
        if arguments.contains("--updatetest") {
            UpdateTest.run(install: arguments.contains("--install"))
        } else if arguments.contains("--zoomtest") {
            ZoomTest.run()
        } else if arguments.contains("--canvastest") {
            CanvasTest.run()
        } else if let repo = BridgeTest.repo(arguments: arguments) {
            BridgeTest.run(repo: repo)
        } else if let path = DiffTest.path(arguments: arguments) {
            DiffTest.run(path: path)
        } else if arguments.contains("--perftest") {
            PerfTest.run()
        } else if let directory = ChromeTest.probeDirectory(arguments: arguments) {
            // Deliberately does not take over from the scene: this one measures
            // the window SwiftUI makes, so the app has to come up normally.
            ChromeTest.probeRealWindow(writingTo: directory)
        } else if arguments.contains("--formattest") {
            FormatTest.run()
        } else if arguments.contains("--chrometest") {
            ChromeTest.run(shots: ChromeTest.shotsDirectory(arguments: arguments))
        } else if arguments.contains("--browsertest") {
            BrowserTest.run(keep: arguments.contains("--keep"))
        } else if arguments.contains("--hooktest") {
            HookTest.run(keep: arguments.contains("--keep"))
        } else if arguments.contains("--launchtest") {
            LaunchTest.run()
        } else if let repos = SelfTest.repoPaths(arguments: arguments) {
            SelfTest.run(
                repoPaths: repos,
                keep: arguments.contains("--keep"),
                name: SelfTest.value("--name", in: arguments),
                branch: SelfTest.value("--branch", in: arguments)
            )
        } else if let request = SnapshotRequest(arguments: arguments) {
            Snapshot.run(request)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
