import AppKit
import CoreAudio
import Foundation

/// Plays the system sound-effect cues that the Audio settings toggle controls.
/// Honors `audioSoundEffectsEnabled` + `audioSoundEffectsVolume` UserDefaults.
@MainActor
enum AudioFeedback {

    enum Cue {
        case start, stop, snip, paste, error

        var systemSoundName: String {
            switch self {
            case .start: return "Tink"
            case .stop:  return "Pop"
            case .snip:  return "Submarine"
            case .paste: return "Tink"
            case .error: return "Funk"
            }
        }
    }

    static func play(_ cue: Cue) {
        let enabled = (UserDefaults.standard.object(forKey: "audioSoundEffectsEnabled") as? Bool) ?? true
        guard enabled else { return }
        let volume = (UserDefaults.standard.object(forKey: "audioSoundEffectsVolume") as? Double) ?? 0.7

        guard let sound = NSSound(named: NSSound.Name(cue.systemSoundName)) else { return }
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
    }
}

/// "What should playback do when recording starts?" — the Audio settings picker
/// has three options: nothing / pause / lower volume. This helper applies the
/// chosen behavior at recording start and reverts at stop.
@MainActor
enum PlaybackController {

    private static var savedSystemVolume: Float?

    static func recordingDidStart() {
        let mode = UserDefaults.standard.string(forKey: "audioPlaybackOnRecord") ?? "nothing"
        switch mode {
        case "pause":
            sendMediaPauseKey()
        case "duck":
            duckSystemOutput(toRatio: 0.2)
        default:
            break
        }
    }

    static func recordingDidEnd() {
        let mode = UserDefaults.standard.string(forKey: "audioPlaybackOnRecord") ?? "nothing"
        switch mode {
        case "pause":
            // Don't auto-resume — user might not want it. They can ⌘P themselves.
            break
        case "duck":
            restoreSystemOutput()
        default:
            break
        }
    }

    /// Sends the system-wide Play/Pause media key (NX_KEYTYPE_PLAY).
    /// Works for Spotify, Music, Safari/Chrome video tabs, QuickTime, etc.
    /// Uses NSEvent.otherEvent → cgEvent → post pattern; NSEvent itself doesn't
    /// have a post(), it has cgEvent which does.
    private static func sendMediaPauseKey() {
        postMediaKey(keyCode: NX_KEYTYPE_PLAY, isDown: true)
        postMediaKey(keyCode: NX_KEYTYPE_PLAY, isDown: false)
    }

    private static func postMediaKey(keyCode: Int32, isDown: Bool) {
        let data1 = (Int(keyCode) << 16) | ((isDown ? 0xa : 0xb) << 8)
        guard let nsEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ),
        let cgEvent = nsEvent.cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }

    /// Lowers the *default-output* device's master volume by `ratio` (e.g.
    /// 0.2 = 20% of current). Saves the previous level so `restoreSystemOutput()`
    /// can put it back. Best-effort — silently no-ops if Core Audio rejects
    /// the property write (some HDMI / external DACs don't expose volume).
    private static func duckSystemOutput(toRatio ratio: Float) {
        guard let device = defaultOutputDevice() else { return }
        guard let current = readMainVolume(device: device) else {
            DebugLog.shared.log(icon: "🔉", label: "Duck skipped",
                                value: "device has no software volume", ok: false)
            return
        }
        savedSystemVolume = current
        let target = max(0.0, min(1.0, current * ratio))
        if writeMainVolume(device: device, value: target) {
            DebugLog.shared.log(icon: "🔉", label: "Duck system audio",
                                value: "\(Int(current * 100))% → \(Int(target * 100))%")
        } else {
            DebugLog.shared.log(icon: "🔉", label: "Duck failed",
                                value: "Core Audio property write rejected", ok: false)
            savedSystemVolume = nil
        }
    }

    private static func restoreSystemOutput() {
        guard let saved = savedSystemVolume,
              let device = defaultOutputDevice() else {
            savedSystemVolume = nil
            return
        }
        if writeMainVolume(device: device, value: saved) {
            DebugLog.shared.log(icon: "🔉", label: "Restore system audio",
                                value: "\(Int(saved * 100))%")
        }
        savedSystemVolume = nil
    }

    // MARK: - Core Audio HAL helpers

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return err == noErr ? deviceID : nil
    }

    private static func readMainVolume(device: AudioDeviceID) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume)
        return err == noErr ? volume : nil
    }

    @discardableResult
    private static func writeMainVolume(device: AudioDeviceID, value: Float) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var v = Float32(value)
        let err = AudioObjectSetPropertyData(
            device, &addr, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &v)
        return err == noErr
    }
}

private let NX_KEYTYPE_PLAY: Int32 = 16
