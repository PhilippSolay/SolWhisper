import AVFoundation
import SwiftUI

/// All audio-related settings: mic device + capture quality + playback handling
/// during recording + sound effects. Per the user spec these consolidate from
/// what used to be split between Transcription's "Audio enhancement" toggle
/// and Meetings → Audio.
struct AudioSettingsView: View {

    @AppStorage("audioInputDeviceUID")     private var deviceUID            = ""
    @AppStorage("audioPlaybackOnRecord")   private var playbackOnRecord     = "nothing"
    @AppStorage("audioSoundEffectsEnabled") private var soundEffectsEnabled = true
    @AppStorage("audioSoundEffectsVolume") private var soundEffectsVolume   = 0.7

    @State private var inputDevices: [AudioDeviceOption] = []

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: $deviceUID) {
                    Text("System default").tag("")
                    ForEach(inputDevices) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                .onChange(of: deviceUID) { newValue in
                    PreferredInputDevice.set(uid: newValue.isEmpty ? nil : newValue)
                }
            } header: { Text("Microphone") } footer: {
                Text("Pick the mic used for dictation and meeting recording. \"System default\" follows macOS Sound preferences.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Playback when recording", selection: $playbackOnRecord) {
                    Text("Do nothing").tag("nothing")
                    Text("Pause").tag("pause")
                    Text("Lower volume (20%)").tag("duck")
                }
            } header: { Text("Playback") } footer: {
                Text("Behavior when you start dictation or a meeting and audio is already playing in another app.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Enable sound effects", isOn: $soundEffectsEnabled)
                if soundEffectsEnabled {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundColor(.secondary)
                        Slider(value: $soundEffectsVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
                    }
                }
            } header: { Text("Sound Effects") } footer: {
                Text("Subtle clicks when recording starts/stops, snip captures, and pastes complete.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio")
        .onAppear { reloadDevices() }
    }

    private func reloadDevices() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            // macOS 13 only exposes the built-in mic via DiscoverySession.
            // External mics still show up at the system level — users pick
            // them via macOS Sound prefs, which our default-routing respects.
            types = [.builtInMicrophone]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        )
        inputDevices = session.devices.map { dev in
            AudioDeviceOption(uid: dev.uniqueID, name: dev.localizedName)
        }.sorted(by: { $0.name < $1.name })
    }
}

private struct AudioDeviceOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}
