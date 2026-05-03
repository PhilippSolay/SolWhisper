import AppKit
import Foundation

/// Sprint 8 — first-launch consent disclaimer for meeting recording.
///
/// Surfaces an alert the FIRST time the user clicks "Record meeting". The user
/// must click Continue to proceed; clicking Cancel aborts the recording start.
/// Tracked via `hasAcceptedRecordingDisclaimer` in UserDefaults — a one-time
/// flag, never re-shown.
enum PrivacyDisclaimer {

    private static let acceptedKey = "hasAcceptedRecordingDisclaimer"

    static var hasAccepted: Bool {
        UserDefaults.standard.bool(forKey: acceptedKey)
    }

    /// Shows the modal if the user hasn't accepted yet. Returns `true` if it's
    /// safe to proceed with recording.
    @MainActor
    static func ensureAccepted() -> Bool {
        if hasAccepted { return true }

        let alert = NSAlert()
        alert.messageText = "About to record this conversation"
        alert.informativeText = """
        SolWhisper records your microphone and other apps' audio (when system audio is granted) to your local disk only. Recordings stay on this Mac — nothing is uploaded unless you explicitly enable an integration.

        By continuing, you confirm that you have consent from all participants where required by the laws of your jurisdiction.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = false

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: acceptedKey)
            return true
        }
        return false
    }
}
