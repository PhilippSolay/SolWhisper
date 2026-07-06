import AppKit
import Carbon.HIToolbox
import Foundation

/// Global hotkeys using Carbon RegisterEventHotKey.
/// Works system-wide without Accessibility permission.
class HotkeyManager {

    var onHotkeyPressed: (() -> Void)?
    var onPauseHotkeyPressed: (() -> Void)?
    var onSnipHotkeyPressed:  (() -> Void)?
    /// Toggles meeting recording — same shape as the dictation hotkey
    /// (one combo, press to start, press again to stop).
    var onMeetingHotkeyPressed: (() -> Void)?
    /// Opens the Transcripts window (global; menu item shortcut only fires
    /// when the menu is visible).
    var onTranscriptsHotkeyPressed: (() -> Void)?
    /// Triggers the screen-Translate flow (capture region → OCR → bubble).
    var onTranslateHotkeyPressed: (() -> Void)?
    /// Triggers the voice-Translate flow (speak → transcribe → translate → paste).
    var onVoiceTranslateHotkeyPressed: (() -> Void)?

    private var hotKeyRef:              EventHotKeyRef?
    private var pauseHotKeyRef:         EventHotKeyRef?
    private var snipHotKeyRef:          EventHotKeyRef?
    private var meetingHotKeyRef:       EventHotKeyRef?
    private var transcriptsHotKeyRef:   EventHotKeyRef?
    private var translateHotKeyRef:     EventHotKeyRef?
    private var voiceTranslateHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef:        EventHandlerRef?
    private var defaultsObserver: Any?

    /// Track last-registered values to avoid redundant re-registration
    private var lastRecordKey:         (Int, Int) = (0, 0)
    private var lastPauseKey:          (Int, Int) = (0, 0)
    private var lastSnipKey:           (Int, Int) = (0, 0)
    private var lastMeetingKey:        (Int, Int) = (0, 0)
    private var lastTranscriptsKey:    (Int, Int) = (0, 0)
    private var lastTranslateKey:      (Int, Int) = (0, 0)
    private var lastVoiceTranslateKey: (Int, Int) = (0, 0)

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
        if let ref = hotKeyRef            { UnregisterEventHotKey(ref); hotKeyRef            = nil }
        if let ref = pauseHotKeyRef       { UnregisterEventHotKey(ref); pauseHotKeyRef       = nil }
        if let ref = snipHotKeyRef        { UnregisterEventHotKey(ref); snipHotKeyRef        = nil }
        if let ref = meetingHotKeyRef     { UnregisterEventHotKey(ref); meetingHotKeyRef     = nil }
        if let ref = transcriptsHotKeyRef { UnregisterEventHotKey(ref); transcriptsHotKeyRef = nil }
        if let ref = translateHotKeyRef   { UnregisterEventHotKey(ref); translateHotKeyRef   = nil }
        if let ref = voiceTranslateHotKeyRef { UnregisterEventHotKey(ref); voiceTranslateHotKeyRef = nil }
        if let ref = eventHandlerRef      { RemoveEventHandler(ref);     eventHandlerRef      = nil }
        if let obs = defaultsObserver      { NotificationCenter.default.removeObserver(obs) }
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
                    } else if hkID.id == 3 {
                        mgr.onSnipHotkeyPressed?()
                    } else if hkID.id == 4 {
                        mgr.onMeetingHotkeyPressed?()
                    } else if hkID.id == 5 {
                        mgr.onTranscriptsHotkeyPressed?()
                    } else if hkID.id == 6 {
                        mgr.onTranslateHotkeyPressed?()
                    } else if hkID.id == 7 {
                        mgr.onVoiceTranslateHotkeyPressed?()
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
        let skc   = UserDefaults.standard.integer(forKey: "snipHotkeyKeyCode")
        let smask = UserDefaults.standard.integer(forKey: "snipHotkeyModifierMask")
        let mkc   = UserDefaults.standard.integer(forKey: "meetingHotkeyKeyCode")
        let mmask = UserDefaults.standard.integer(forKey: "meetingHotkeyModifierMask")
        let tkc   = UserDefaults.standard.integer(forKey: "transcriptsHotkeyKeyCode")
        let tmask = UserDefaults.standard.integer(forKey: "transcriptsHotkeyModifierMask")
        let xkc   = UserDefaults.standard.integer(forKey: "translateHotkeyKeyCode")
        let xmask = UserDefaults.standard.integer(forKey: "translateHotkeyModifierMask")
        let vkc   = UserDefaults.standard.integer(forKey: "voiceTranslateHotkeyKeyCode")
        let vmask = UserDefaults.standard.integer(forKey: "voiceTranslateHotkeyModifierMask")

        let rec  = (kc, mask)
        let pau  = (pkc, pmask)
        let snip = (skc, smask)
        let meet = (mkc, mmask)
        let trans = (tkc, tmask)
        let xlate = (xkc, xmask)
        let vxlate = (vkc, vmask)
        guard rec != lastRecordKey || pau != lastPauseKey
              || snip != lastSnipKey || meet != lastMeetingKey
              || trans != lastTranscriptsKey
              || xlate != lastTranslateKey
              || vxlate != lastVoiceTranslateKey else { return }
        registerHotKeys()
    }

    func registerHotKeys() {
        // Unregister previous bindings
        if let ref = hotKeyRef            { UnregisterEventHotKey(ref); hotKeyRef            = nil }
        if let ref = pauseHotKeyRef       { UnregisterEventHotKey(ref); pauseHotKeyRef       = nil }
        if let ref = snipHotKeyRef        { UnregisterEventHotKey(ref); snipHotKeyRef        = nil }
        if let ref = meetingHotKeyRef     { UnregisterEventHotKey(ref); meetingHotKeyRef     = nil }
        if let ref = transcriptsHotKeyRef { UnregisterEventHotKey(ref); transcriptsHotKeyRef = nil }
        if let ref = translateHotKeyRef   { UnregisterEventHotKey(ref); translateHotKeyRef   = nil }
        if let ref = voiceTranslateHotKeyRef { UnregisterEventHotKey(ref); voiceTranslateHotKeyRef = nil }

        // Record hotkey
        let kc   = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let keyCode   = UInt32(kc   != 0 ? kc   : 15)
        let carbonMod = carbonModifiers(mask != 0 ? mask : 11)

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
        let pauseCarbonMod = carbonModifiers(pmask != 0 ? pmask : 11)

        var pauseID = EventHotKeyID(signature: 0x5357_4853, id: 2)
        let perr = RegisterEventHotKey(pauseKeyCode, pauseCarbonMod, pauseID,
                                       GetApplicationEventTarget(), 0, &pauseHotKeyRef)
        lastPauseKey = (pkc, pmask)
        Task { @MainActor in
            DebugLog.shared.log(icon: "⌨️",
                                label: "Pause hotkey: keyCode=\(pauseKeyCode) mods=\(pauseCarbonMod)",
                                ok: perr == noErr)
        }

        // Snip (OCR) hotkey — ships unset. We only register when the user
        // has explicitly picked one (both keyCode and modifierMask non-zero).
        let skc   = UserDefaults.standard.integer(forKey: "snipHotkeyKeyCode")
        let smask = UserDefaults.standard.integer(forKey: "snipHotkeyModifierMask")
        lastSnipKey = (skc, smask)
        if skc > 0 && smask > 0 {
            var snipID = EventHotKeyID(signature: 0x5357_4853, id: 3)
            let snipKey = UInt32(skc)
            let snipMod = carbonModifiers(smask)
            let serr = RegisterEventHotKey(snipKey, snipMod, snipID,
                                           GetApplicationEventTarget(), 0, &snipHotKeyRef)
            Task { @MainActor in
                DebugLog.shared.log(icon: "⌨️",
                                    label: "Snip hotkey: keyCode=\(snipKey) mods=\(snipMod)",
                                    ok: serr == noErr)
            }
        }

        // Meeting toggle hotkey — also ships unset. One combo, toggles the
        // meeting state machine (start when idle, stop when recording/paused).
        let mkc   = UserDefaults.standard.integer(forKey: "meetingHotkeyKeyCode")
        let mmask = UserDefaults.standard.integer(forKey: "meetingHotkeyModifierMask")
        lastMeetingKey = (mkc, mmask)
        if mkc > 0 && mmask > 0 {
            var meetID = EventHotKeyID(signature: 0x5357_4853, id: 4)
            let meetKey = UInt32(mkc)
            let meetMod = carbonModifiers(mmask)
            let merr = RegisterEventHotKey(meetKey, meetMod, meetID,
                                           GetApplicationEventTarget(), 0, &meetingHotKeyRef)
            Task { @MainActor in
                DebugLog.shared.log(icon: "⌨️",
                                    label: "Meeting hotkey: keyCode=\(meetKey) mods=\(meetMod)",
                                    ok: merr == noErr)
            }
        }

        // Transcripts window hotkey — global open. Tray menu has its own
        // shortcut (which only fires when the menu is up); this is the
        // system-wide trigger.
        let tkc   = UserDefaults.standard.integer(forKey: "transcriptsHotkeyKeyCode")
        let tmask = UserDefaults.standard.integer(forKey: "transcriptsHotkeyModifierMask")
        lastTranscriptsKey = (tkc, tmask)
        if tkc > 0 && tmask > 0 {
            var transID = EventHotKeyID(signature: 0x5357_4853, id: 5)
            let transKey = UInt32(tkc)
            let transMod = carbonModifiers(tmask)
            let terr = RegisterEventHotKey(transKey, transMod, transID,
                                            GetApplicationEventTarget(), 0, &transcriptsHotKeyRef)
            Task { @MainActor in
                DebugLog.shared.log(icon: "⌨️",
                                    label: "Transcripts hotkey: keyCode=\(transKey) mods=\(transMod)",
                                    ok: terr == noErr)
            }
        }

        // Translate hotkey — same shape as snip: ships unset, only registers
        // when the user has explicitly picked one. Hotkey ID 6 is reserved
        // for translate; matches `onTranslateHotkeyPressed`.
        let xkc   = UserDefaults.standard.integer(forKey: "translateHotkeyKeyCode")
        let xmask = UserDefaults.standard.integer(forKey: "translateHotkeyModifierMask")
        lastTranslateKey = (xkc, xmask)
        if xkc > 0 && xmask > 0 {
            var xlateID = EventHotKeyID(signature: 0x5357_4853, id: 6)
            let xlateKey = UInt32(xkc)
            let xlateMod = carbonModifiers(xmask)
            let xerr = RegisterEventHotKey(xlateKey, xlateMod, xlateID,
                                            GetApplicationEventTarget(), 0, &translateHotKeyRef)
            Task { @MainActor in
                DebugLog.shared.log(icon: "⌨️",
                                    label: "Translate hotkey: keyCode=\(xlateKey) mods=\(xlateMod)",
                                    ok: xerr == noErr)
            }
        }

        // Voice-Translate hotkey — same shape as translate/snip: ships unset,
        // only registers when the user has explicitly picked one. Hotkey ID 7
        // is reserved for voice-translate; matches `onVoiceTranslateHotkeyPressed`.
        let vkc   = UserDefaults.standard.integer(forKey: "voiceTranslateHotkeyKeyCode")
        let vmask = UserDefaults.standard.integer(forKey: "voiceTranslateHotkeyModifierMask")
        lastVoiceTranslateKey = (vkc, vmask)
        if vkc > 0 && vmask > 0 {
            var voiceID = EventHotKeyID(signature: 0x5357_4853, id: 7)
            let voiceKey = UInt32(vkc)
            let voiceMod = carbonModifiers(vmask)
            let verr = RegisterEventHotKey(voiceKey, voiceMod, voiceID,
                                           GetApplicationEventTarget(), 0, &voiceTranslateHotKeyRef)
            Task { @MainActor in
                DebugLog.shared.log(icon: "⌨️",
                                    label: "Voice-Translate hotkey: keyCode=\(voiceKey) mods=\(voiceMod)",
                                    ok: verr == noErr)
            }
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
