import AppKit

enum PasteManager {

    // MARK: - Accessibility

    static var hasAccessibility: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    static func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        Task { @MainActor in
            DebugLog.shared.log(icon: "🔐", label: "Accessibility",
                                value: trusted ? "granted" : "NOT granted",
                                ok: trusted)
        }
    }

    /// Fired (MainActor) when the text could not be auto-inserted and is left on
    /// the clipboard for a manual ⌘V — the app wires this to a visible notice so
    /// the failure isn't silent (the top "I dictated and nothing happened" case).
    @MainActor static var onClipboardFallback: (() -> Void)?

    // MARK: - Paste

    @MainActor
    static func paste(text: String, into target: NSRunningApplication?) async {

        // 1. Ensure the text is on the clipboard. Skip the clear+set if the
        // caller already wrote it (additive clipboard relies on the
        // changeCount it captured being preserved).
        let pb = NSPasteboard.general
        if pb.string(forType: .string) != text {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        DebugLog.shared.log(
            icon: "📋", label: "Paste start",
            value: "target=\(target?.localizedName ?? "nil") ax=\(hasAccessibility)"
        )

        guard let target else {
            DebugLog.shared.log(icon: "📋", label: "Paste skipped",
                                value: "no target app", ok: false)
            return
        }

        // 2. Activate target
        target.activate(options: .activateIgnoringOtherApps)

        let deadline = Date().addingTimeInterval(0.8)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        DebugLog.shared.log(icon: "📋", label: "Activate",
                            value: "\(target.localizedName ?? "?") front=\(isFront)", ok: isFront)

        // 3. Stabilize — let text field regain focus
        try? await Task.sleep(nanoseconds: 150_000_000)

        // 4. Try paste methods in order of reliability

        // Method A: osascript subprocess — most reliable, uses shell-level permissions
        if osascriptPaste() {
            DebugLog.shared.log(icon: "📋", label: "osascript Cmd+V", value: "ok")
            return
        }
        DebugLog.shared.log(icon: "📋", label: "osascript Cmd+V", value: "failed", ok: false)

        // Method B: NSAppleScript in-process
        let asErr = appleScriptPaste()
        if asErr == nil {
            DebugLog.shared.log(icon: "📋", label: "AppleScript Cmd+V", value: "ok")
            return
        }
        DebugLog.shared.log(icon: "📋", label: "AppleScript Cmd+V",
                            value: asErr ?? "failed", ok: false)

        // Method C: AX direct insert
        if hasAccessibility {
            if axInsert(text: text) {
                DebugLog.shared.log(icon: "📋", label: "AX insert", value: "ok")
                return
            }
            DebugLog.shared.log(icon: "📋", label: "AX insert", value: "failed", ok: false)
        }

        // Method D: CGEvent
        sendCmdV(to: target)

        // Reaching here means methods A–C already failed. Without Accessibility,
        // none of them (nor CGEvent) can reliably insert — the text is only on
        // the clipboard. Surface that instead of failing silently.
        if !hasAccessibility {
            onClipboardFallback?()
        }
        DebugLog.shared.log(icon: "📋", label: "Paste result",
                            value: "text on clipboard — press ⌘V if needed", ok: false)
    }

    // MARK: - Method A: osascript subprocess

    /// Runs osascript as a child process. Returns true if exit code is 0.
    private static func osascriptPaste() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", """
            tell application "System Events" to keystroke "v" using command down
            """]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Method B: NSAppleScript in-process

    private static func appleScriptPaste() -> String? {
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let err = errorInfo {
            return err[NSAppleScript.errorMessage] as? String ?? "unknown error"
        }
        return nil
    }

    // MARK: - Method C: AX direct insert

    private static func axInsert(text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef) == .success,
              let focusedRef else { return false }

        // `.success` guarantees non-nil but NOT that the value is an
        // AXUIElement — apps with non-conformant AX or a mid-transition focus
        // can hand back a different CFType. Force-casting that is an
        // unrecoverable crash, so verify the CFTypeID first.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let focused = focusedRef as! AXUIElement
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Method D: CGEvent

    @MainActor
    private static func sendCmdV(to app: NSRunningApplication) {
        let src = CGEventSource(stateID: .combinedSessionState)

        func makeV(_ down: Bool) -> CGEvent? {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: down)
            e?.flags = .maskCommand
            return e
        }

        makeV(true)?.postToPid(app.processIdentifier)
        makeV(false)?.postToPid(app.processIdentifier)
        makeV(true)?.post(tap: .cgAnnotatedSessionEventTap)
        makeV(false)?.post(tap: .cgAnnotatedSessionEventTap)

        DebugLog.shared.log(icon: "📋", label: "CGEvent Cmd+V",
                            value: "pid=\(app.processIdentifier) ax=\(hasAccessibility)")
    }
}
