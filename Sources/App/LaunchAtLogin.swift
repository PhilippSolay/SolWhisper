import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` that exposes a published
/// `isEnabled` flag for SwiftUI binding. macOS 13+.
@MainActor
final class LaunchAtLogin: ObservableObject {

    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    private init() {
        refresh()
    }

    /// Re-reads the SMAppService status — useful at launch in case the user
    /// toggled launch-on-login via System Settings while we were closed.
    func refresh() {
        guard #available(macOS 13.0, *) else {
            isEnabled = false
            return
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Toggles registration. Mirrors the new state into `isEnabled` and
    /// records any error for the UI to surface.
    func setEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            lastError = "Launch on login requires macOS 13 or later."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            DebugLog.shared.log(icon: "🚀", label: "Launch-at-login failed",
                                value: error.localizedDescription, ok: false)
        }
        // Re-read truth from SMAppService rather than trusting the call's
        // return — the framework can settle into a different state.
        refresh()
    }
}
