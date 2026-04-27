import SwiftUI
import AppKit

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case transcription = "Transcription"
    case aiPolish      = "AI Polish"
    case vocabulary    = "Vocabulary"
    case hotkey        = "Hotkey"
    case debug         = "Debug"
    case about         = "About"

    var id: Self { self }

    var icon: String {
        switch self {
        case .transcription: "waveform"
        case .aiPolish:      "sparkles"
        case .vocabulary:    "text.book.closed"
        case .hotkey:        "keyboard"
        case .debug:         "ant"
        case .about:         "info.circle"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @State private var selection: SettingsSection? = .transcription

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
                switch selection ?? .transcription {
                case .transcription: TranscriptionSettingsView()
                case .aiPolish:      AIPolishSettingsView()
                case .vocabulary:    VocabularySettingsView()
                case .hotkey:        HotkeySettingsView()
                case .debug:         DebugSettingsView()
                case .about:         AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar(.hidden)
    }
}

// MARK: - Transcription

struct TranscriptionSettingsView: View {
    @AppStorage("transcriptionBackend") private var backend          = "apple"
    @AppStorage("deepgramApiKey")       private var deepgramApiKey   = ""
    @AppStorage("audioEnhancement")     private var audioEnhancement = true
    @State private var deepgramVisible = false

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Backend", selection: $backend) {
                    Text("Apple Speech  (free · on-device)").tag("apple")
                    Text("Deepgram nova-3  (higher accuracy)").tag("deepgram")
                }

                if backend == "apple" {
                    Text("On-device · no API key · works offline")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    APIKeyField(label: "Deepgram API Key",
                                text: $deepgramApiKey,
                                visible: $deepgramVisible)
                }
            }

            Section {
                Toggle("Audio enhancement", isOn: $audioEnhancement)
                if audioEnhancement {
                    Text("Compression · AGC · Noise gate — boosts quiet mics and suppresses background noise.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: { Text("Audio") }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
    }
}

// MARK: - AI Polish

struct AIPolishSettingsView: View {
    @AppStorage("enableLLMPolish")       private var enableLLMPolish      = true
    @AppStorage("openRouterApiKey")      private var openRouterApiKey     = ""
    @AppStorage("openRouterModel")       private var openRouterModel      = "anthropic/claude-3-5-haiku"
    @AppStorage("polishRemoveFiller")    private var removeFiller         = true
    @AppStorage("polishFixPunctuation")  private var fixPunctuation       = true
    @AppStorage("polishFixGrammar")      private var fixGrammar           = false
    @State private var openRouterVisible = false
    @State private var customModelText   = ""

    private let presetModels: [(id: String, label: String)] = [
        ("anthropic/claude-3-5-haiku",         "Claude 3.5 Haiku (fast)"),
        ("anthropic/claude-3-5-sonnet",        "Claude 3.5 Sonnet"),
        ("openai/gpt-4o-mini",                 "GPT-4o Mini"),
        ("openai/gpt-4o",                      "GPT-4o"),
        ("google/gemini-flash-1.5",            "Gemini Flash 1.5"),
        ("meta-llama/llama-3.1-8b-instruct",   "Llama 3.1 8B"),
    ]

    private var isCustomModel: Bool {
        !presetModels.map(\.id).contains(openRouterModel)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remove filler words & fix grammar", isOn: $enableLLMPolish)
            } footer: {
                Text("Polishes raw transcription using an LLM after each recording.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if enableLLMPolish {
                Section {
                    Toggle("Remove filler words", isOn: $removeFiller)
                    Toggle("Fix punctuation & capitalization", isOn: $fixPunctuation)
                    Toggle("Fix grammar", isOn: $fixGrammar)
                } header: {
                    Text("Cleanup Level")
                } footer: {
                    Text("Choose what the AI corrects. Less cleanup = closer to your original words.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("API Key") {
                    APIKeyField(label: "OpenRouter API Key",
                                text: $openRouterApiKey,
                                visible: $openRouterVisible)
                    Link("Get a free OpenRouter key →",
                         destination: URL(string: "https://openrouter.ai")!)
                        .font(.system(size: 12))
                }

                Section("Model") {
                    Picker("Model", selection: modelBinding) {
                        ForEach(presetModels, id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                    if isCustomModel {
                        TextField("Model ID (e.g. mistralai/mistral-7b-instruct)",
                                  text: $openRouterModel)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Polish")
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { isCustomModel ? "custom" : openRouterModel },
            set: { if $0 != "custom" { openRouterModel = $0 } }
        )
    }
}

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
    @AppStorage("hotkeyModifierMask")      private var hotkeyModifierMask      = 10
    @AppStorage("pauseHotkeyKeyCode")      private var pauseHotkeyKeyCode      = 35
    @AppStorage("pauseHotkeyModifierMask") private var pauseHotkeyModifierMask = 10
    @State private var isRecordingHotkey      = false
    @State private var isRecordingPauseHotkey = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Record / Stop")
                    Spacer()
                    HotkeyRecorderButton(
                        keyCode:      $hotkeyKeyCode,
                        modifierMask: $hotkeyModifierMask,
                        isRecording:  $isRecordingHotkey
                    )
                }
                HStack {
                    Text("Current").foregroundColor(.secondary)
                    Spacer()
                    Text(hotkeyDisplayString(keyCode: hotkeyKeyCode, modifierMask: hotkeyModifierMask))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }

            Section {
                HStack {
                    Text("Pause / Resume")
                    Spacer()
                    HotkeyRecorderButton(
                        keyCode:      $pauseHotkeyKeyCode,
                        modifierMask: $pauseHotkeyModifierMask,
                        isRecording:  $isRecordingPauseHotkey
                    )
                }
                HStack {
                    Text("Current").foregroundColor(.secondary)
                    Spacer()
                    Text(hotkeyDisplayString(keyCode: pauseHotkeyKeyCode, modifierMask: pauseHotkeyModifierMask))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            } footer: {
                Text("Click the button then press your desired key combination. A modifier key (⌘ ⌥ ⌃ ⇧) is required.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hotkey")
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
        }
        .formStyle(.grouped)
        .navigationTitle("Debug")
    }
}

// MARK: - About

struct AboutSettingsView: View {
    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        Image("SolWhisperLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        Text("SolWhisper").fontWeight(.semibold)
                        Text(appVersion)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Section {
                Link("Deepgram Console", destination: URL(string: "https://console.deepgram.com")!)
                Link("OpenRouter",       destination: URL(string: "https://openrouter.ai")!)
            }

            Section {
                HStack {
                    Spacer()
                    Text("Made with Love  ·  Studio Solay")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
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

    private var displayText: Binding<String> {
        Binding(
            get: { visible ? text : String(repeating: "•", count: min(text.count, 32)) },
            set: { _ in }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .opacity(visible ? 1 : 0)
                if !visible {
                    TextField(label, text: displayText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                }
            }
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
