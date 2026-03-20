import Carbon
import AppKit

class HotkeyManager {

    var onHotkeyPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Default hotkey: Option + Command + R
    private let targetKeyCode: CGKeyCode = 15 // R
    private let targetModifiers: CGEventFlags = [.maskAlternate, .maskCommand]

    func startListening() {
        let eventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .keyDown,
                  let refcon = refcon else { return Unmanaged.passRetained(event) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift])

            if keyCode == manager.targetKeyCode && flags == manager.targetModifiers {
                manager.onHotkeyPressed?()
                return nil // Consume event
            }

            return Unmanaged.passRetained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: refcon
        )

        guard let eventTap = eventTap else {
            print("HotkeyManager: Failed to create event tap. Make sure Accessibility permissions are granted.")
            requestAccessibilityPermission()
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stopListening() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        AXIsProcessTrustedWithOptions(options)
    }

    deinit {
        stopListening()
    }
}
