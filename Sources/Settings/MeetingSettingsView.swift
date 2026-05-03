import SwiftUI

struct MeetingSettingsView: View {

    @AppStorage("meetingsAutoSummarize")  private var autoSummarize     = true
    @AppStorage("meetingsAutoIntegrate")  private var autoIntegrate     = false
    @AppStorage("meetingsDefaultSkillID") private var defaultSkillID    = "generic"
    @AppStorage("meetingsAutoCleanTranscript") private var autoCleanTranscript = true
    @AppStorage("meetingsAudioDucking")   private var audioDucking      = true
    @AppStorage("meetingsClippingDetect") private var clippingDetect    = true
    @AppStorage("meetingsChunkSeconds")   private var chunkSeconds      = 30
    @AppStorage("meetingsRecordingDisclosure") private var showDisclosure = true
    @AppStorage("meetingsRootPath")       private var meetingsRootPath  = ""

    @StateObject private var skillsRegistry = SkillsRegistry.shared

    private let chunkOptions = [15, 30, 60]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoCleanTranscript) {
                    HStack(spacing: 4) {
                        Text("Auto-clean transcript after stop")
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .help("Removes filler words (um, uh, like...), fixes punctuation, and tightens grammar without changing meaning. You can also clean any meeting on demand from the Transcripts window.")
                    }
                }
                Toggle("Auto-summarize after stop", isOn: $autoSummarize)
                Picker("Default skill", selection: $defaultSkillID) {
                    if !skillsRegistry.skillPacks.isEmpty {
                        Section("Skill packs") {
                            ForEach(skillsRegistry.skillPacks) { pack in
                                Text(pack.name).tag(pack.id)
                            }
                        }
                    }
                    Section("Skills") {
                        ForEach(skillsRegistry.skills) { skill in
                            Text(skill.name).tag(skill.id)
                        }
                    }
                }
                .disabled(!autoSummarize)
                Toggle("Auto-send to integrations after summary", isOn: $autoIntegrate)
                    .disabled(!autoSummarize)
            } header: { Text("Summary") } footer: {
                Text("After stop: stitch audio → optionally clean transcript → run summary with the chosen skill → optionally fan-out to enabled integrations.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Side-chain ducking (lowers other-app audio when you speak)", isOn: $audioDucking)
                Toggle("Clipping detector", isOn: $clippingDetect)
                Picker("Chunk size", selection: $chunkSeconds) {
                    ForEach(chunkOptions, id: \.self) { Text("\($0) s").tag($0) }
                }
            } header: { Text("Audio") } footer: {
                Text("Larger chunks = fewer disk writes but more lost audio if the app crashes mid-recording.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Show disclosure overlay during recording", isOn: $showDisclosure)
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("By recording, you confirm you have consent from all participants where required by law.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("Privacy") }

            Section {
                HStack {
                    Text(currentMeetingsRootDisplay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([currentMeetingsRoot])
                    }
                    Button("Move folder…") {
                        moveFolder()
                    }
                }
            } header: { Text("Storage") } footer: {
                Text("Choose a different location for your meetings (e.g. iCloud Drive). Existing meetings are moved over.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Meetings")
    }

    // MARK: - Storage path helpers

    private var currentMeetingsRoot: URL {
        if !meetingsRootPath.isEmpty {
            return URL(fileURLWithPath: meetingsRootPath, isDirectory: true)
        }
        return MeetingStore.defaultRoot
    }

    private var currentMeetingsRootDisplay: String {
        let path = currentMeetingsRoot.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Lets the user pick a new directory + offers to move the existing
    /// folder there. We require an app restart for the new path to take
    /// effect everywhere (MeetingStore captures the root at init time).
    private func moveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder to store SolWhisper meetings"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let chosenParent = panel.url else { return }

        let oldRoot = currentMeetingsRoot
        let newRoot = chosenParent.appendingPathComponent("SolWhisper-Meetings",
                                                          isDirectory: true)

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: oldRoot.path), oldRoot != newRoot {
                if fm.fileExists(atPath: newRoot.path) {
                    let alert = NSAlert()
                    alert.messageText = "A folder named \"SolWhisper-Meetings\" already exists at the chosen location."
                    alert.informativeText = "Pick a different parent folder, or remove the existing one."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }
                try fm.moveItem(at: oldRoot, to: newRoot)
            } else {
                try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            }
            meetingsRootPath = newRoot.path

            let alert = NSAlert()
            alert.messageText = "Meetings folder moved."
            alert.informativeText = "Restart SolWhisper for the new location to take effect everywhere."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                Self.relaunchApp()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't move the meetings folder."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
