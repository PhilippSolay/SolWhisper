import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys using Carbon RegisterEventHotKey.
/// Works system-wide without Accessibility permission.
class HotkeyManager {

    var onHotkeyPressed: (() -> Void)?
    var onPauseHotkeyPressed: (() -> Void)?

    private var hotKeyRef:       EventHotKeyRef?
    private var pauseHotKeyRef:  EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var defaultsObserver: Any?

    /// Track last-registered values to avoid redundant re-registration
    private var lastRecordKey:  (Int, Int) = (0, 0)
    private var lastPauseKey:   (Int, Int) = (0, 0)

    // MARK: - Start / Stop

    func startListening() {
        if let obs = defaultsObserver { NotificationCenter.default.removeObserver(obs); defaultsObserver = nil }

        installCarbonHandler()
        registerHotKeys()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerHotKeysIfChanged()
        }
    }

    func stopListening() {
        if let ref = hotKeyRef       { UnregisterEventHotKey(ref);  hotKeyRef       = nil }
        if let ref = pauseHotKeyRef  { UnregisterEventHotKey(ref);  pauseHotKeyRef  = nil }
        if let ref = eventHandlerRef { RemoveEventHandler(ref);      eventHandlerRef = nil }
        if let obs = defaultsObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Carbon event handler (installed once)

    private func installCarbonHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let ptr = userData, let event else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()

                // Read the hotkey ID to distinguish record vs pause
                var hkID = EventHotKeyID()
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil,
                                  MemoryLayout<EventHotKeyID>.size,
                                  nil,
                                  &hkID)

                DispatchQueue.main.async {
                    if hkID.id == 1 {
                        mgr.onHotkeyPressed?()
                    } else if hkID.id == 2 {
                        mgr.onPauseHotkeyPressed?()
                    }
                }
                return noErr
            },
            1, &spec, selfPtr, &eventHandlerRef
        )
    }

    // MARK: - Register / update hot keys

    /// Only re-register if hotkey values actually changed
    private func registerHotKeysIfChanged() {
        let kc    = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        let mask  = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let pkc   = UserDefaults.standard.integer(forKey: "pauseHotkeyKeyCode")
        let pmask = UserDefaults.standard.integer(forKey: "pauseHotkeyModifierMask")

        let rec  = (kc, mask)
        let pau  = (pkc, pmask)
        guard rec != lastRecordKey || pau != lastPauseKey else { return }
        registerHotKeys()
    }

    func registerHotKeys() {
        // Unregister previous bindings
        if let ref = hotKeyRef      { UnregisterEventHotKey(ref); hotKeyRef      = nil }
        if let ref = pauseHotKeyRef { UnregisterEventHotKey(ref); pauseHotKeyRef = nil }

        // Record hotkey
        let kc   = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let keyCode   = UInt32(kc   != 0 ? kc   : 15)
        let carbonMod = carbonModifiers(mask != 0 ? mask : 10)

        var hkID = EventHotKeyID(signature: 0x5357_4853, id: 1)
        let err = RegisterEventHotKey(keyCode, carbonMod, hkID,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        lastRecordKey = (kc, mask)
        Task { @MainActor in
            DebugLog.shared.log(icon: "⌨️",
                                label: "Record hotkey: keyCode=\(keyCode) mods=\(carbonMod)",
                                ok: err == noErr)
        }

        // Pause hotkey
        let pkc   = UserDefaults.standard.integer(forKey: "pauseHotkeyKeyCode")
        let pmask = UserDefaults.standard.integer(forKey: "pauseHotkeyModifierMask")
        let pauseKeyCode   = UInt32(pkc   != 0 ? pkc   : 35)
        let pauseCarbonMod = carbonModifiers(pmask != 0 ? pmask : 10)

        var pauseID = EventHotKeyID(signature: 0x5357_4853, id: 2)
        let perr = RegisterEventHotKey(pauseKeyCode, pauseCarbonMod, pauseID,
                                       GetApplicationEventTarget(), 0, &pauseHotKeyRef)
        lastPauseKey = (pkc, pmask)
        Task { @MainActor in
            DebugLog.shared.log(icon: "⌨️",
                                label: "Pause hotkey: keyCode=\(pauseKeyCode) mods=\(pauseCarbonMod)",
                                ok: perr == noErr)
        }
    }

    // MARK: - Helpers

    private func carbonModifiers(_ mask: Int) -> UInt32 {
        var m: UInt32 = 0
        if mask & 1 != 0 { m |= UInt32(controlKey) }
        if mask & 2 != 0 { m |= UInt32(optionKey)  }
        if mask & 4 != 0 { m |= UInt32(shiftKey)   }
        if mask & 8 != 0 { m |= UInt32(cmdKey)     }
        return m
    }

    deinit { stopListening() }
}
