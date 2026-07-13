import SwiftUI
import AppKit

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    // Sidebar order matches the user-requested layout. `rawValue` is what
    // displays in the sidebar; case names stay short for the switch.
    case home          = "Home"
    case transcription = "Dictation"
    case meetings      = "Meetings"
    case ocr           = "Screen Capture"
    case translate     = "Translate"
    case voiceTranslate = "Voice Translate"
    case languages     = "Languages"
    case audio         = "Audio"
    case hotkey        = "Hotkey"
    case models        = "Models"
    case skills        = "Skills"
    case people        = "People"
    case vocabulary    = "Vocabulary"
    case integrations  = "Integrations"
    case debug         = "Debug"

    var id: Self { self }

    var icon: String {
        switch self {
        case .home:          "house"
        case .transcription: "waveform"
        case .meetings:      "person.2.wave.2"
        case .ocr:           "rectangle.dashed.and.paperclip"
        case .translate:     "globe"
        case .voiceTranslate: "globe.badge.chevron.backward"
        case .languages:     "character.bubble"
        case .audio:         "speaker.wave.3"
        case .hotkey:        "keyboard"
        case .models:        "brain"
        case .skills:        "wand.and.stars"
        case .people:        "person.crop.square.filled.and.at.rectangle"
        case .vocabulary:    "text.book.closed"
        case .integrations:  "arrow.left.arrow.right"
        case .debug:         "ant"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @State private var selection: SettingsSection? = .home

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            Group {
                switch selection ?? .home {
                case .home:          HomeSettingsView()
                case .transcription: TranscriptionSettingsView()
                case .meetings:      MeetingSettingsView()
                case .ocr:           OCRSettingsView()
                case .translate:     TranslateSettingsView()
                case .voiceTranslate: VoiceTranslateSettingsView()
                case .languages:     LanguagesSettingsView()
                case .audio:         AudioSettingsView()
                case .hotkey:        HotkeySettingsView()
                case .models:        ModelsSettingsView()
                case .skills:        SkillsSettingsView()
                case .people:        PeopleSettingsView()
                case .vocabulary:    VocabularySettingsView()
                case .integrations:  IntegrationsSettingsView()
                case .debug:         DebugSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar(.hidden)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    @AppStorage("showLiveTranscript")   private var showLiveTranscript = true
    @AppStorage("dictationAutoPaste")   private var dictationAutoPaste = true

    // Additive clipboard — appends each transcript to the pasteboard instead
    // of replacing it. Optional clear-on-paste wipes after ⌘V (needs AX).
    @AppStorage("clipboardAdditive")           private var clipboardAdditive = false
    @AppStorage("clipboardAdditiveClearOnPaste") private var clipboardClearOnPaste = true

    // AI Polish — folded in from the deprecated AI Polish section.
    @AppStorage("enableLLMPolish")      private var enableLLMPolish    = true
    @AppStorage("polishRemoveFiller")   private var removeFiller       = true
    @AppStorage("polishFixPunctuation") private var fixPunctuation     = true
    @AppStorage("polishFixGrammar")     private var fixGrammar         = false

    var body: some View {
        Form {
            Section {
                Toggle("Show live transcript", isOn: $showLiveTranscript)
            } header: {
                Text("Display")
            } footer: {
                Text("Shows a transcript bubble below the pill while you're speaking. Polished text is pasted at the end.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle(isOn: $dictationAutoPaste) {
                    HStack(spacing: 4) {
                        Text("Paste result text")
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.secondary)
                            .help("On: paste the polished transcript into the previously-focused app. Off: only copy to clipboard so you can paste manually with ⌘V.")
                    }
                }
                .toggleStyle(.switch)

                Toggle("Additive clipboard", isOn: $clipboardAdditive)
                    .toggleStyle(.switch)
                    .help("Each new dictation appends to the clipboard with a blank-line separator instead of replacing it.")

                if clipboardAdditive {
                    Toggle("Clear automatically", isOn: $clipboardClearOnPaste)
                        .toggleStyle(.switch)
                        .padding(.leading, 16)
                        .help("After you paste with ⌘V, the clipboard is wiped — only if SolWhisper still owns it. Requires Accessibility permission.")
                }
            } header: {
                Text("Output")
            } footer: {
                if clipboardAdditive {
                    Text("Each new dictation is appended to the clipboard instead of replacing it. Clear automatically empties the clipboard after the next ⌘V (requires Accessibility permission).")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onChange(of: clipboardAdditive)         { _ in refreshClearTap() }
            .onChange(of: clipboardClearOnPaste)     { _ in refreshClearTap() }

            Section {
                Toggle("Polish transcription with AI", isOn: $enableLLMPolish)
                if enableLLMPolish {
                    Toggle("Remove filler words",            isOn: $removeFiller)
                    Toggle("Fix punctuation & capitalization", isOn: $fixPunctuation)
                    Toggle("Fix grammar",                     isOn: $fixGrammar)
                }
            } header: { Text("AI Polish") } footer: {
                Text("Cleans up the raw transcript via the LLM picked in Models → Routing. Less cleanup = closer to your original words.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
    }

    @MainActor
    private func refreshClearTap() {
        if clipboardAdditive && clipboardClearOnPaste {
            AdditiveClipboard.shared.startClearOnPasteIfNeeded()
        } else {
            AdditiveClipboard.shared.stopClearOnPaste()
        }
    }
}

/// Reusable WhisperKit model picker — used twice in `ModelsSettingsView`,
/// once for STT Short, once for STT Meetings.
struct WhisperKitModelPicker: View {
    let title: String
    @Binding var modelID: String

    // Shared coordinator, NOT view-local @State: the settings detail pane is
    // rebuilt on every sidebar switch, so local state died mid-download and
    // the orphaned task kept running invisibly. The shared object survives
    // navigation and lets both pickers reflect the same download.
    @ObservedObject private var downloader = WhisperKitModelDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: $modelID) {
                ForEach(WhisperKitClient.supportedModels, id: \.self) { m in
                    Text(modelLabel(for: m)).tag(m)
                }
            }
            .onChange(of: modelID) { _ in
                WhisperKitClient.resetCache()
            }

            let displayName = WhisperKitClient.displayName(for: modelID)
            if let fraction = downloader.progress[modelID] {
                ProgressView(value: fraction) {
                    Text("Downloading \(displayName)… \(Int(fraction * 100))%")
                        .font(.caption)
                }
            } else if WhisperKitClient.isModelDownloaded(modelID) {
                Text("✓ \(displayName) available offline")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Button("Download \(displayName) now") {
                    downloader.download(modelID)
                }
            }
            if let err = downloader.lastError[modelID] {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
    }

    // Sizes are the real on-disk download totals from the HF repo (the old
    // labels quoted parameter counts as MB). tiny.en really is bigger than
    // base.en — its repo folder ships duplicate .mlpackage copies.
    private func modelLabel(for model: String) -> String {
        switch model {
        case "tiny.en":  return "tiny.en — 145 MB · fastest, lower accuracy"
        case "base.en":  return "base.en — 139 MB · balanced (default)"
        case "small.en": return "small.en — 463 MB · better accuracy"
        case "large-v3-v20240930_626MB":
            return "large-v3-turbo (compressed) — 597 MB · near-best accuracy"
        case "large-v3-v20240930":
            return "large-v3-turbo — 1.5 GB · best accuracy"
        default:         return model
        }
    }
}

// (Old AI Polish + About settings views were deleted — folded into
//  Transcription and Home respectively. The fenced-out copy is gone.)

// MARK: - Vocabulary

struct VocabularySettingsView: View {
    @State private var words:   [String] = []
    @State private var newWord: String   = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add word or phrase…", text: $newWord)
                        .onSubmit { addWord() }
                    Button("Add") { addWord() }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Custom Vocabulary")
            } footer: {
                Text("These words are included in the AI polish prompt so the model spells them correctly every time.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if !words.isEmpty {
                Section("Words (\(words.count))") {
                    ForEach(words, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button {
                                words.removeAll { $0 == word }
                                save()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { words.remove(atOffsets: $0); save() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Vocabulary")
        .onAppear(perform: load)
    }

    // MARK: Helpers

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !words.contains(w) else { return }
        words.append(w)
        save()
        newWord = ""
    }

    private func load() {
        guard let data = UserDefaults.standard.string(forKey: "customVocabulary")?
                             .data(using: .utf8),
              let arr  = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        words = arr
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(words),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(str, forKey: "customVocabulary")
    }
}

// MARK: - Hotkey

struct HotkeySettingsView: View {
    @AppStorage("hotkeyKeyCode")           private var hotkeyKeyCode           = 15
    @AppStorage("hotkeyModifierMask")      private var hotkeyModifierMask      = 11
    @AppStorage("pauseHotkeyKeyCode")      private var pauseHotkeyKeyCode      = 35
    @AppStorage("pauseHotkeyModifierMask") private var pauseHotkeyModifierMask = 11
    /// Snip hotkey ships unset (0/0). User picks one in this UI.
    @AppStorage("snipHotkeyKeyCode")       private var snipHotkeyKeyCode       = 0
    @AppStorage("snipHotkeyModifierMask")  private var snipHotkeyModifierMask  = 0
    /// Meeting toggle hotkey — same shape: one combo, toggles start/stop.
    @AppStorage("meetingHotkeyKeyCode")      private var meetingHotkeyKeyCode      = 0
    @AppStorage("meetingHotkeyModifierMask") private var meetingHotkeyModifierMask = 0
    /// Transcripts window hotkey — global open.
    @AppStorage("transcriptsHotkeyKeyCode")      private var transcriptsHotkeyKeyCode      = 0
    @AppStorage("transcriptsHotkeyModifierMask") private var transcriptsHotkeyModifierMask = 0
    /// Translate Snap hotkey — paired with the Translate-from-screen flow.
    @AppStorage("translateHotkeyKeyCode")        private var translateHotkeyKeyCode        = 0
    @AppStorage("translateHotkeyModifierMask")   private var translateHotkeyModifierMask   = 0
    /// Voice-translate hotkey — speak, then paste the translation. Ships unset.
    @AppStorage("voiceTranslateHotkeyKeyCode")      private var voiceTranslateHotkeyKeyCode      = 0
    @AppStorage("voiceTranslateHotkeyModifierMask") private var voiceTranslateHotkeyModifierMask = 0
    @State private var isRecordingHotkey         = false
    @State private var isRecordingPauseHotkey    = false
    @State private var isRecordingSnipHotkey     = false
    @State private var isRecordingMeetingHotkey  = false
    @State private var isRecordingTranscriptsHotkey = false
    @State private var isRecordingTranslateHotkey   = false
    @State private var isRecordingVoiceTranslateHotkey = false

    var body: some View {
        Form {
            Section {
                HotkeyRow(
                    title: "Start/Stop Recording",
                    subtitle: "Starts and stops dictation",
                    keyCode:      $hotkeyKeyCode,
                    modifierMask: $hotkeyModifierMask,
                    isRecording:  $isRecordingHotkey
                )
                HotkeyRow(
                    title: "Pause / Resume",
                    subtitle: "Pauses without losing the recording",
                    keyCode:      $pauseHotkeyKeyCode,
                    modifierMask: $pauseHotkeyModifierMask,
                    isRecording:  $isRecordingPauseHotkey
                )
                HotkeyRow(
                    title: "Start / Stop Meeting",
                    subtitle: "Toggles meeting recording",
                    keyCode:      $meetingHotkeyKeyCode,
                    modifierMask: $meetingHotkeyModifierMask,
                    isRecording:  $isRecordingMeetingHotkey
                )
                HotkeyRow(
                    title: "Open Transcripts",
                    subtitle: "Opens the meeting browser window",
                    keyCode:      $transcriptsHotkeyKeyCode,
                    modifierMask: $transcriptsHotkeyModifierMask,
                    isRecording:  $isRecordingTranscriptsHotkey
                )
                HotkeyRow(
                    title: "Text Snap",
                    subtitle: "Drag a region; recognized text goes to clipboard",
                    keyCode:      $snipHotkeyKeyCode,
                    modifierMask: $snipHotkeyModifierMask,
                    isRecording:  $isRecordingSnipHotkey
                )
                HotkeyRow(
                    title: "Translate Snap",
                    subtitle: "Drag a region; translated text goes to clipboard",
                    keyCode:      $translateHotkeyKeyCode,
                    modifierMask: $translateHotkeyModifierMask,
                    isRecording:  $isRecordingTranslateHotkey
                )
                HotkeyRow(
                    title: "Voice Translate",
                    subtitle: "Speak, then paste the translation in your target language",
                    keyCode:      $voiceTranslateHotkeyKeyCode,
                    modifierMask: $voiceTranslateHotkeyModifierMask,
                    isRecording:  $isRecordingVoiceTranslateHotkey
                )
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut field, then press your desired combination. A modifier key (⌘ ⌥ ⌃ ⇧) is required. Click ✗ to clear.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hotkey")
    }
}

/// Compact one-row layout for a single hotkey binding. Title + subtitle on the
/// left, X (clear) + chip-style recorder on the right. Pattern modeled on the
/// macOS System Settings → Keyboard → Shortcuts panel.
private struct HotkeyRow: View {
    let title: String
    let subtitle: String
    @Binding var keyCode: Int
    @Binding var modifierMask: Int
    @Binding var isRecording: Bool

    private var isSet: Bool { keyCode > 0 && modifierMask > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 16)
            if isRecording {
                // Cancel the listening state — flipping the binding makes the
                // recorder NSView re-render to its idle state.
                Button {
                    isRecording = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel — keep current shortcut")
            } else if isSet {
                Button {
                    keyCode = 0
                    modifierMask = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
            HotkeyRecorderButton(
                keyCode:      $keyCode,
                modifierMask: $modifierMask,
                isRecording:  $isRecording
            )
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Debug

struct DebugSettingsView: View {
    @AppStorage("debugMode") private var debugMode = false

    var body: some View {
        Form {
            Section {
                Toggle("Debug mode", isOn: $debugMode)
            } footer: {
                Text("Logs API calls, timing, and token usage in the panel below.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if debugMode {
                Section("Log") {
                    DebugLogView()
                        .frame(height: 260)
                }
            }

            Section {
                Button("Open Setup Guide…") {
                    (NSApp.delegate as? AppDelegate)?.openOnboarding()
                }
            } header: { Text("Tools") } footer: {
                Text("Re-runs the first-launch onboarding flow. Useful for testing.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Debug")
    }
}

// MARK: - Debug Log View

private struct DebugLogView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var copied = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private func copyAll() {
        let lines = log.entries.map { e -> String in
            var line = "\(Self.timeFmt.string(from: e.timestamp))  \(e.icon)  \(e.label)"
            if let v = e.value  { line += " — \(v)" }
            if let m = e.ms     { line += " (\(m)ms)" }
            if let t = e.tokens { line += " ↑\(t.prompt) ↓\(t.completion)" }
            return line
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(log.entries.count) entries")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button {
                    copyAll()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(copied ? .secondary : .primary)
                }
                .buttonStyle(.plain)
                .help("Copy log to clipboard")
                .padding(.trailing, 6)
                Button("Clear") { log.clear() }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if log.entries.isEmpty {
                Text("No entries yet — start recording to see debug output.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.entries) { entry in
                            DebugRow(entry: entry)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }
}

private struct DebugRow: View {
    let entry: LogEntry

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Self.timeFmt.string(from: entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(entry.icon).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(entry.ok ? .primary : .red)
                if let val = entry.value {
                    Text(val)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                if let ms = entry.ms {
                    Text("\(ms)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ms > 2000 ? .orange : .secondary)
                }
                if let tok = entry.tokens {
                    Text("↑\(tok.prompt) ↓\(tok.completion)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

// MARK: - API Key Field

struct APIKeyField: View {
    let label: String
    @Binding var text: String
    @Binding var visible: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A real TextField when revealed, a native SecureField when masked.
            // Both are genuine, focusable fields bound to the same `text`, so
            // ⌘C/⌘V work and there is no invisible opacity-0 layer to type into.
            Group {
                if visible {
                    TextField(label, text: $text)
                } else {
                    SecureField(label, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)   // keys read left-to-right
            .autocorrectionDisabled(true)

            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(visible ? "Hide key" : "Show key")
        }
    }
}

// MARK: - Hotkey Recorder Button

struct HotkeyRecorderButton: View {
    @Binding var keyCode:      Int
    @Binding var modifierMask: Int
    @Binding var isRecording:  Bool

    var body: some View {
        HotkeyRecorderRepresentable(
            keyCode:      $keyCode,
            modifierMask: $modifierMask,
            isRecording:  $isRecording
        )
        .frame(width: 140, height: 26)
    }
}

private struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var keyCode:      Int
    @Binding var modifierMask: Int
    @Binding var isRecording:  Bool

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.onRecorded = { kc, mod in
            keyCode      = kc
            modifierMask = mod
            isRecording  = false
        }
        v.onRecordingStateChanged = { isRecording = $0 }
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.label        = hotkeyDisplayString(keyCode: keyCode, modifierMask: modifierMask)
        nsView.isRecording  = isRecording
        nsView.needsDisplay = true
    }
}

final class HotkeyRecorderNSView: NSView {
    var label: String = ""
    var isRecording = false
    var onRecorded: ((Int, Int) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let text    = isRecording ? "Press shortcut…" : (label.isEmpty ? "Click to record" : label)
        let color   = isRecording ? NSColor.labelColor : NSColor.labelColor
        let bgColor = isRecording ? NSColor.labelColor.withAlphaComponent(0.1)
                                  : NSColor.controlBackgroundColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        bgColor.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz  = str.size()
        str.draw(at: NSPoint(x: (bounds.width - sz.width) / 2,
                             y: (bounds.height - sz.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        onRecordingStateChanged?(true)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        if event.keyCode == 53 {
            isRecording = false
            onRecordingStateChanged?(false)
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }
        let mod = modifierMaskFromFlags(event.modifierFlags)
        guard mod != 0 else { return }
        onRecorded?(Int(event.keyCode), mod)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        onRecordingStateChanged?(false)
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

// MARK: - Helpers

func modifierMaskFromFlags(_ flags: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if flags.contains(.control) { m |= 1 }
    if flags.contains(.option)  { m |= 2 }
    if flags.contains(.shift)   { m |= 4 }
    if flags.contains(.command) { m |= 8 }
    return m
}

func hotkeyDisplayString(keyCode: Int, modifierMask: Int) -> String {
    var s = ""
    if modifierMask & 1 != 0 { s += "⌃" }
    if modifierMask & 2 != 0 { s += "⌥" }
    if modifierMask & 4 != 0 { s += "⇧" }
    if modifierMask & 8 != 0 { s += "⌘" }
    s += keyCodeToString(keyCode)
    return s
}
