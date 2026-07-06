import AppKit

/// Additive clipboard mode. When enabled, each new dictation transcript is
/// appended to the existing clipboard contents (separated by a blank line)
/// instead of replacing them.
///
/// "Clear automatically" sub-mode listens for ⌘V via a CGEvent tap (requires
/// Accessibility). After paste lands, the clipboard is wiped — but only if it
/// still holds the appended buffer we wrote (changeCount match).
@MainActor
final class AdditiveClipboard {

    static let shared = AdditiveClipboard()

    /// changeCount of the last write we made. Used by clear-on-paste to confirm
    /// nothing else has touched the pasteboard since.
    private var ownedChangeCount: Int = -1

    private var keyMonitor: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Replaces or appends to the system pasteboard depending on the user's
    /// settings. Always returns the string that ended up on the pasteboard
    /// (useful for Paste-result-text to fire a paste with the same content).
    @discardableResult
    func write(_ text: String) -> String {
        let pb = NSPasteboard.general
        let isAdditive = UserDefaults.standard.bool(forKey: "clipboardAdditive")

        let final: String
        if isAdditive,
           let existing = pb.string(forType: .string),
           !existing.isEmpty {
            final = existing + "\n\n" + text
        } else {
            final = text
        }

        pb.clearContents()
        pb.setString(final, forType: .string)
        ownedChangeCount = pb.changeCount

        if isAdditive {
            DebugLog.shared.log(icon: "📋", label: "Additive clipboard",
                                value: "appended \(text.count) chars (total \(final.count))")
        }
        return final
    }

    // MARK: - Clear-on-paste tap

    /// Installs the global key tap that watches for ⌘V and wipes the
    /// pasteboard after paste lands. Idempotent. Silent no-op if Accessibility
    /// is not granted (we'll re-check on next start).
    func startClearOnPasteIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "clipboardAdditive"),
              UserDefaults.standard.bool(forKey: "clipboardAdditiveClearOnPaste") else {
            stopClearOnPaste()
            return
        }
        guard PasteManager.hasAccessibility else {
            DebugLog.shared.log(icon: "📋", label: "Clear-on-paste skipped",
                                value: "Accessibility not granted", ok: false)
            return
        }
        guard keyMonitor == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                // macOS disables an event tap that runs too long or on certain
                // user input, delivering the disable as a special event type
                // through this same callback. If we don't re-enable it, the tap
                // stays dead and clear-on-paste silently stops for the session.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let me = Unmanaged<AdditiveClipboard>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = me.keyMonitor { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown,
                      let refcon else { return Unmanaged.passUnretained(event) }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                // V == 0x09. Match ⌘V regardless of other modifiers being absent.
                if keyCode == 0x09 && flags.contains(.maskCommand) {
                    let me = Unmanaged<AdditiveClipboard>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async { me.handlePasteFired() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            DebugLog.shared.log(icon: "📋", label: "Clear-on-paste tap",
                                value: "tapCreate failed", ok: false)
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyMonitor = tap
        runLoopSource = src
        DebugLog.shared.log(icon: "📋", label: "Clear-on-paste tap", value: "enabled")
    }

    func stopClearOnPaste() {
        if let tap = keyMonitor {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        keyMonitor = nil
        runLoopSource = nil
    }

    private func handlePasteFired() {
        // Schedule the clear AFTER the paste has had a chance to land.
        let owned = ownedChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let pb = NSPasteboard.general
            // Only clear if we still own the pasteboard contents — i.e. nothing
            // else copied between our write and this paste.
            guard pb.changeCount == owned else {
                DebugLog.shared.log(icon: "📋", label: "Clear-on-paste skipped",
                                    value: "pasteboard changed since write")
                return
            }
            pb.clearContents()
            DebugLog.shared.log(icon: "📋", label: "Clear-on-paste", value: "cleared after ⌘V")
        }
    }
}
