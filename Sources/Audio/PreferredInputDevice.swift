import AVFoundation
import CoreAudio
import Foundation

/// Single source of truth for the user-selected microphone. All audio engines
/// (AppleSpeechClient, MeetingAudioEngine, WhisperKitClient's mic recorder)
/// consult `applyToInputNode(_:)` before installing a tap to route audio
/// through the chosen device.
///
/// Storage: `audioInputDeviceUID` in UserDefaults. Empty string = system default.
enum PreferredInputDevice {

    /// User's chosen UID, or nil for system default.
    static var uid: String? {
        let v = UserDefaults.standard.string(forKey: "audioInputDeviceUID") ?? ""
        return v.isEmpty ? nil : v
    }

    /// Sets the preferred device + posts a notification so already-running
    /// audio engines can re-apply if they want.
    static func set(uid: String?) {
        UserDefaults.standard.set(uid ?? "", forKey: "audioInputDeviceUID")
        NotificationCenter.default.post(name: .preferredInputDeviceChanged, object: nil)
    }

    /// Maps an `AVCaptureDevice.uniqueID` to a Core Audio `AudioDeviceID`.
    /// Returns nil if the device isn't currently present.
    static func coreAudioDeviceID(for uid: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                              &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size, &deviceIDs) == noErr else { return nil }

        for id in deviceIDs {
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var devUID: CFString = "" as CFString
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            withUnsafeMutablePointer(to: &devUID) { ptr in
                _ = AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &nameSize, ptr)
            }
            if devUID as String == uid { return id }
        }
        return nil
    }

    /// Routes the given AVAudioEngine's input through the preferred device.
    /// Must be called BEFORE `engine.start()` (or after a stop/start cycle).
    /// No-op when no preferred device is set.
    ///
    /// macOS HAL gotcha: `kAudioOutputUnitProperty_CurrentDevice` only takes
    /// effect when the audio unit is uninitialized. Setting it on an already-
    /// initialized unit silently no-ops and the unit keeps reading the OLD
    /// device's format, so the tap receives no buffers. We Uninitialize
    /// before SetProperty and let AVAudioEngine's start path Initialize —
    /// previously we did the Initialize ourselves, but that confused
    /// AVAudioEngine's internal lifecycle accounting and left the unit
    /// holding the device open after engine.stop() (visible to users as the
    /// macOS orange microphone indicator persisting after they stopped).
    static func applyToInputNode(_ engine: AVAudioEngine) {
        guard let uid else { return }
        guard let cadID = coreAudioDeviceID(for: uid) else {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🎤", label: "Mic device not found",
                                    value: "uid=\(uid) — falling back to system default",
                                    ok: false)
            }
            return
        }
        guard let unit = engine.inputNode.audioUnit else { return }

        // Uninitialize first. Safe to call even if not yet initialized —
        // returns kAudioUnitErr_Uninitialized which we ignore.
        _ = AudioUnitUninitialize(unit)

        var deviceID = cadID
        let setResult = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if setResult != noErr {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🎤", label: "Mic routing — set failed",
                                    value: "uid=\(uid) status=\(setResult)", ok: false)
            }
        } else {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🎤", label: "Mic routed",
                                    value: "uid=\(uid) coreAudioID=\(cadID)")
            }
        }
        // Note: AVAudioEngine.start() will Initialize the unit itself.
    }

    /// Explicitly Uninitializes the engine's input audio unit so macOS
    /// releases the device immediately. Call after `engine.stop()` from
    /// every teardown path (stopAndFinalize, cancel, error fallback) so
    /// the OS-level mic-in-use indicator clears the moment the user stops
    /// recording — `engine.stop()` alone does not always release the
    /// device on macOS.
    static func releaseInputNode(_ engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else { return }
        _ = AudioUnitUninitialize(unit)
    }

    /// Lists currently-attached audio input devices (`AVCaptureDevice` UID + name).
    /// Used by Settings + tray menu to render the picker.
    static func availableInputs() -> [(uid: String, name: String)] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { (uid: $0.uniqueID, name: $0.localizedName) }
                              .sorted(by: { $0.name < $1.name })
    }
}

extension Notification.Name {
    static let preferredInputDeviceChanged = Notification.Name("cloud.solay.SolWhisper.preferredInputDeviceChanged")
}
