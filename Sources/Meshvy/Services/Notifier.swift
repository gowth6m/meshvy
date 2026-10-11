import AppKit
import Observation
import UserNotifications

/// Key a notification carries the node it should land on under.
private let revealKey = "meshvy.node"

/// Tells you about an agent you are not looking at.
///
/// Three escalating signals, because only the first is guaranteed to work: a
/// Dock badge counting the agents that need you, a bounce of the Dock icon, and
/// an OS notification you can click to land on the node. The notification needs
/// both a bundle and the user's consent — an unsigned development binary has
/// neither, and `UNUserNotificationCenter.current()` traps outright when there
/// is no bundle, so it is never touched until one is confirmed.
@MainActor
@Observable
final class Notifier: NSObject {
    /// Off until asked for, so nothing is posted behind the user's back.
    var isEnabled = false {
        didSet { if isEnabled, !hasAsked { requestAuthorization() } }
    }
    private(set) var isAuthorized = false
    private var hasAsked = false

    /// Nil outside an app bundle (`swift run`, the headless harnesses), which is
    /// also exactly when the notification APIs are unsafe to call.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
        guard isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        guard isBundled, !hasAsked else { return }
        hasAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.isAuthorized = granted }
        }
    }

    /// `node` is the storage key of the node to land on when the notification is
    /// clicked. Returns without posting when notifications are switched off —
    /// the badge and the in-app markers carry the news instead.
    func post(title: String, body: String?, node: NodeID) {
        NSApp.requestUserAttention(.informationalRequest)
        guard isEnabled, isAuthorized, isBundled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        if let body, !body.isEmpty { content.body = body }
        content.sound = .default
        content.userInfo = [revealKey: node.storageKey]

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// How many agents are waiting on you, shown on the Dock icon. Zero clears it.
    func badge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Clicking a notification focuses the window and centres the node — which
    /// is the whole point of sending one.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo[revealKey] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let key, let id = NodeID(storageKey: key) { MeshvyStore.shared.reveal(id) }
            completionHandler()
        }
    }

    /// Show it even when Meshvy is frontmost — the window may be covering a
    /// different workspace than the agent that just finished.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
