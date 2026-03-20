import Carbon
import AppKit

class HotkeyManager {

    var onHotkeyPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Read live from UserDefaults so hotkey changes take effect without restart
    private var targetKeyCode: CGKeyCode {
        let stored = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        return CGKeyCode(stored != 0 ? stored : 15) // default: R
    }

    private var targetCGFlags: CGEventFlags {
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let effective = mask != 0 ? mask : 10 // default: ⌥⌘
        return cgFlagsFromMask(effective)
    }

    func startListening() {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown, let refcon = refcon else {
                return Unmanaged.passRetained(event)
            }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags   = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])

            if keyCode == manager.targetKeyCode && flags == manager.targetCGFlags {
                manager.onHotkeyPressed?()
                return nil // consume
            }
            return Unmanaged.passRetained(event)
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        )

        guard let tap = eventTap else {
            print("HotkeyManager: failed to create event tap — grant Accessibility permission.")
            requestAccessibilityPermission()
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopListening() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    private func requestAccessibilityPermission() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        AXIsProcessTrustedWithOptions(opts)
    }

    deinit { stopListening() }
}

// MARK: - Modifier mask conversion
// Bitmask: bit0=⌃ bit1=⌥ bit2=⇧ bit3=⌘

func cgFlagsFromMask(_ mask: Int) -> CGEventFlags {
    var flags: CGEventFlags = []
    if mask & 1 != 0 { flags.insert(.maskControl) }
    if mask & 2 != 0 { flags.insert(.maskAlternate) }
    if mask & 4 != 0 { flags.insert(.maskShift) }
    if mask & 8 != 0 { flags.insert(.maskCommand) }
    return flags
}
