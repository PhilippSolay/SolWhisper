import AVFoundation
import CoreAudio
import Foundation

/// Detects audio device changes during a meeting:
///   - The default input device changing (user selected a different mic)
///   - An input device disappearing (USB unplugged, BT disconnect)
///   - Bluetooth route changes
///
/// State machine surfaces three values:
///   .healthy            — current device available, on a wired/built-in route
///   .btWarning(name)    — connected over Bluetooth (lower bandwidth, may stutter)
///   .disconnected(name) — the device the meeting started on is gone
///
/// Wired into `MeetingController` to surface the warning as a pill chip color
/// and (for `.disconnected`) auto-pause + offer to switch to a different mic.
@MainActor
final class DeviceMonitor: ObservableObject {

    enum Health: Equatable {
        case healthy(deviceName: String)
        case btWarning(deviceName: String)
        case disconnected(lostName: String)
    }

    enum Event: Equatable {
        case devicesChanged
        case inputLost(name: String)
    }

    @Published private(set) var health: Health = .healthy(deviceName: "Built-in")
    var onEvent: ((Event) -> Void)?

    /// The device the meeting was started with (recorded when `start()` is called).
    /// We compare against this on every change; if it disappears, we surface
    /// `.disconnected`.
    private var pinnedDeviceUID: String?
    private var pinnedDeviceName: String = "Built-in"
    private var configObserver: NSObjectProtocol?
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListenerAddr: AudioObjectPropertyAddress?
    private var defaultInputListenerAddr: AudioObjectPropertyAddress?

    // MARK: - Lifecycle

    /// Starts watching. `currentInputUID` is what the meeting actually opened —
    /// pass `PreferredInputDevice.uid` (or whatever the engine chose if nil).
    func start(currentInputUID: String?, currentName: String?) {
        pinnedDeviceUID = currentInputUID
        pinnedDeviceName = currentName ?? "Built-in"
        health = currentRouteHealth()

        // Listen for AVAudioEngine reconfiguration (mic unplug fires this).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAVConfigChange() }
        }

        installHardwareListeners()
    }

    func stop() {
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        removeHardwareListeners()
        pinnedDeviceUID = nil
    }

    deinit {
        if let obs = configObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Snapshot

    /// Computes the current health from the live device list.
    private func currentRouteHealth() -> Health {
        let inputs = PreferredInputDevice.availableInputs()
        // If we pinned a device and it's gone, that's a disconnect.
        if let uid = pinnedDeviceUID,
           !inputs.contains(where: { $0.uid == uid }) {
            return .disconnected(lostName: pinnedDeviceName)
        }
        // Bluetooth heuristic — name contains "AirPods" or "Bluetooth".
        let name = pinnedDeviceName.lowercased()
        if name.contains("airpods") || name.contains("bluetooth") || name.contains("bt") {
            return .btWarning(deviceName: pinnedDeviceName)
        }
        return .healthy(deviceName: pinnedDeviceName)
    }

    // MARK: - Notification handlers

    private func handleAVConfigChange() {
        let inputs = PreferredInputDevice.availableInputs()
        if let uid = pinnedDeviceUID,
           !inputs.contains(where: { $0.uid == uid }) {
            health = .disconnected(lostName: pinnedDeviceName)
            onEvent?(.inputLost(name: pinnedDeviceName))
            DebugLog.shared.log(icon: "🎚", label: "Input lost",
                                value: pinnedDeviceName, ok: false)
            return
        }
        onEvent?(.devicesChanged)
        // Re-evaluate Bluetooth state.
        let prev = health
        let next = currentRouteHealth()
        if prev != next { health = next }
    }

    private func installHardwareListeners() {
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleAVConfigChange() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main,
            block
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddr,
            DispatchQueue.main,
            block
        )
        devicesListenerBlock = block
        defaultInputListenerBlock = block
        devicesListenerAddr = devicesAddr
        defaultInputListenerAddr = defaultInputAddr
    }

    private func removeHardwareListeners() {
        if var addr = devicesListenerAddr, let block = devicesListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
        if var addr = defaultInputListenerAddr, let block = defaultInputListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                DispatchQueue.main,
                block
            )
        }
        devicesListenerBlock = nil
        defaultInputListenerBlock = nil
        devicesListenerAddr = nil
        defaultInputListenerAddr = nil
    }
}
