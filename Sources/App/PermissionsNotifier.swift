import AppKit
import Foundation
import UserNotifications

/// Non-blocking "permissions needed" nudge built on `UNUserNotificationCenter`.
///
/// Replaces the deprecated `NSUserNotification` path, whose action button no
/// longer fires on modern macOS (and which was often silently swallowed). A
/// modal `NSAlert` is intentionally NOT used: `runModal()` enters a nested
/// runloop that starves Swift concurrency during launch (it would deadlock the
/// VoiceProfileBackfill store write). This delivers quietly via provisional
/// authorization — no upfront permission prompt — and its "Open Settings"
/// action deep-links straight to Privacy & Security.
@MainActor
final class PermissionsNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = PermissionsNotifier()
    private override init() { super.init() }

    private let categoryID = "permissions.missing"
    private let openSettingsActionID = "permissions.openSettings"
    private var registered = false

    /// Posts a quiet notification listing the missing permissions.
    func notifyMissing(_ list: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategoryIfNeeded(center)
        // `.provisional` delivers quietly to Notification Center with no upfront
        // prompt; macOS upgrades to full delivery once the user engages once.
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "SolWhisper needs permissions"
            content.body = "Not granted: \(list). Click to open System Settings → Privacy & Security."
            content.categoryIdentifier = self.categoryID
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    private func registerCategoryIfNeeded(_ center: UNUserNotificationCenter) {
        guard !registered else { return }
        registered = true
        let action = UNNotificationAction(identifier: openSettingsActionID,
                                          title: "Open Settings",
                                          options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [action],
                                              intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    /// Handles both the "Open Settings" action and a plain tap on the body.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(url)
            }
            completionHandler()
        }
    }
}
