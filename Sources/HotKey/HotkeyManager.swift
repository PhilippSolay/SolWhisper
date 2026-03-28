import AppKit

/// Global hotkey using NSEvent monitors.
/// Simpler and more reliable than CGEvent tap for unsigned apps.
/// Global monitor fires when other apps are frontmost; local covers when SolWhisper is.
class HotkeyManager {

    var onHotkeyPressed: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor:  Any?

    // Read live so hotkey changes in Settings take effect immediately
    private var targetKeyCode: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return UInt16(stored != 0 ? stored : 15) // default: R
    }

    private var targetModifiers: NSEvent.ModifierFlags {
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let effective = mask != 0 ? mask : 10 // default: ⌥⌘
        var flags: NSEvent.ModifierFlags = []
        if effective & 1 != 0 { flags.insert(.control) }
        if effective & 2 != 0 { flags.insert(.option)  }
        if effective & 4 != 0 { flags.insert(.shift)   }
        if effective & 8 != 0 { flags.insert(.command) }
        return flags
    }

    func startListening() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let relevantFlags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if event.keyCode == self.targetKeyCode && relevantFlags == self.targetModifiers {
                self.onHotkeyPressed?()
            }
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handler($0) }
        localMonitor  = NSEvent.addLocalMonitorForEvents(matching:  .keyDown) { event in
            handler(event)
            return event
        }

        if globalMonitor == nil {
            print("HotkeyManager: global monitor failed — grant Accessibility in System Settings → Privacy → Accessibility")
            requestAccessibility()
        } else {
            print("HotkeyManager: listening for ⌥⌘R (keyCode=\(targetKeyCode) modifiers=\(targetModifiers))")
        }
    }

    func stopListening() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
    }

    private func requestAccessibility() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        AXIsProcessTrustedWithOptions(opts)
    }

    deinit { stopListening() }
}

// Keep cgFlagsFromMask for Settings display (used in SettingsView)
func cgFlagsFromMask(_ mask: Int) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if mask & 1 != 0 { flags.insert(.control) }
    if mask & 2 != 0 { flags.insert(.option)  }
    if mask & 4 != 0 { flags.insert(.shift)   }
    if mask & 8 != 0 { flags.insert(.command) }
    return flags
}
