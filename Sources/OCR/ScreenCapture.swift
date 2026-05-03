import AppKit
import CoreGraphics
import Foundation

/// Wraps `/usr/sbin/screencapture -i -t png <tempURL>` so we get the polished
/// macOS marquee selection (Esc cancels, Space drags, Shift constrains, all
/// for free).
///
/// Returns `(url, rect)` on success, `nil` if the user cancelled (no PNG
/// written) or the helper exited non-zero. The bounding rect is the region
/// the user selected, in screen coordinates — used by `SnipResultBubble`
/// to position itself near where the user just snipped.
enum ScreenCapture {

    struct Result {
        let imageURL: URL
        /// Screen-coordinate rect the user dragged. May be nil if `screencapture`
        /// didn't expose it (it doesn't on a plain `-i`); callers fall back to
        /// "near the mouse cursor" placement when nil.
        let regionInScreenCoordinates: CGRect?
    }

    /// Spawns `screencapture -i -t png <tempURL>` and awaits the user's
    /// selection. The helper foregrounds itself; we restore SolWhisper's
    /// previous focus state via the caller (`pasteTarget` snapshot).
    ///
    /// - Parameter silent: if true, passes `-x` to suppress the shutter sound.
    static func interactive(silent: Bool = true) async -> Result? {
        // The shell-out form of screencapture doesn't trigger the macOS
        // Screen Recording TCC prompt on its own — it just exits with
        // code 1 if the calling app isn't authorized. CGRequestScreenCaptureAccess
        // shows the prompt on the very first call; after that it's silent.
        // We escalate to an actionable alert that opens the right
        // Privacy & Security pane so the user can fix it without hunting.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()   // first-run prompt, silent thereafter
            await MainActor.run {
                DebugLog.shared.log(
                    icon: "✂️",
                    label: "Screen Recording not granted",
                    value: "Open System Settings → Privacy & Security → Screen Recording.",
                    ok: false
                )
                presentScreenRecordingAlert()
            }
            return nil
        }

        let tempURL = makeTempURL()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var args = ["-i", "-t", "png", tempURL.path]
        if silent { args.insert("-x", at: 0) }
        task.arguments = args

        return await withCheckedContinuation { (cont: CheckedContinuation<Result?, Never>) in
            task.terminationHandler = { proc in
                let fm = FileManager.default
                let exists = fm.fileExists(atPath: tempURL.path)
                let size: Int = exists
                    ? ((try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0)
                    : 0
                Task { @MainActor in
                    DebugLog.shared.log(
                        icon: "✂️",
                        label: "screencapture exit",
                        value: "code=\(proc.terminationStatus) fileExists=\(exists) size=\(size)B path=\(tempURL.lastPathComponent)",
                        ok: exists && size > 100
                    )
                }
                cont.resume(returning: exists
                    ? Result(imageURL: tempURL,
                             regionInScreenCoordinates: nil)
                    : nil)
            }
            do {
                try task.run()
            } catch {
                Task { @MainActor in
                    DebugLog.shared.log(icon: "✂️", label: "screencapture launch failed",
                                        value: "\(error)", ok: false)
                }
                cont.resume(returning: nil)
            }
        }
    }

    /// Pops an alert asking the user to grant Screen Recording. The "Open
    /// Settings" button takes them straight to the right pane via the
    /// `x-apple.systempreferences` URL scheme.
    @MainActor
    private static func presentScreenRecordingAlert() {
        let alert = NSAlert()
        alert.messageText = "Text Snap needs Screen Recording access"
        alert.informativeText = """
        macOS blocks screen capture until you grant permission. After enabling SolWhisper in System Settings → Privacy & Security → Screen Recording, you'll need to relaunch the app for the change to take effect.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("solwhisper-snips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snip-\(UUID().uuidString).png")
    }
}
