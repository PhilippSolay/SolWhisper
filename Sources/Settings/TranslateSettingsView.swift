import SwiftUI

/// Settings panel for the Translate-from-screen feature.
/// Three sections:
///   - Engine: Apple (on-device, default on 14.4+) or LLM (via Models routing).
///   - Target language: the default the bubble opens with. Persisted per
///     translation, so this is more of a "first run" seed than a hard pin.
///   - Hotkey: same shape as the other screen actions.
struct TranslateSettingsView: View {

    @AppStorage(TranslationEngineKind.userDefaultsKey)
    private var engineRaw: String = TranslationEngineKind.current.rawValue
    @AppStorage("translateTargetLanguage")
    private var targetLanguage: String = TranslationLanguage.defaultTargetCode
    @AppStorage("translationLLMProvider")
    private var translationLLMProvider: String = "openrouter"

    @AppStorage("translateHotkeyKeyCode")
    private var translateHotkeyKeyCode: Int = 0
    @AppStorage("translateHotkeyModifierMask")
    private var translateHotkeyModifierMask: Int = 0
    @State private var isRecordingTranslateHotkey = false

    @StateObject private var modelStore = ModelStore.shared

    private var supportsAppleTranslation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $engineRaw) {
                    if supportsAppleTranslation {
                        Text("Apple Translation  (on-device · free · offline)")
                            .tag(TranslationEngineKind.apple.rawValue)
                    } else {
                        Text("Apple Translation  (requires macOS 15+)")
                            .tag(TranslationEngineKind.apple.rawValue)
                            .foregroundColor(.secondary)
                    }
                    Text("AI model  (cloud · uses your API key)")
                        .tag(TranslationEngineKind.llm.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: { Text("Engine") } footer: {
                Text(engineFooter)
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Default target", selection: $targetLanguage) {
                    ForEach(TranslationLanguage.curated) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
            } header: { Text("Target language") } footer: {
                Text("Initial target each time you trigger Translate. The bubble remembers the most recent target across sessions.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if engineRaw == TranslationEngineKind.llm.rawValue {
                Section {
                    routingPicker("Translation", selection: $translationLLMProvider)
                } header: { Text("AI model") } footer: {
                    if modelStore.models.isEmpty {
                        Text("No configured models yet — translation falls back to OpenRouter / Ollama defaults. Add a model in Settings → Models to route directly.")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("Fast models (Haiku, Gemini Flash, Llama 3.3 Instant) translate well and finish in under a second.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Section {
                HotkeyRow(
                    title: "Translate Snap",
                    subtitle: "Drag a region; translated text goes to clipboard",
                    keyCode:      $translateHotkeyKeyCode,
                    modifierMask: $translateHotkeyModifierMask,
                    isRecording:  $isRecordingTranslateHotkey
                )
            } header: { Text("Hotkey") } footer: {
                Text("Pick a global shortcut. Click ✗ to clear.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Translate")
    }

    private var engineFooter: String {
        switch TranslationEngineKind(rawValue: engineRaw) ?? .apple {
        case .apple:
            return supportsAppleTranslation
                ? "Apple's on-device translator. First use of a language pair prompts macOS to download the model — about 50 MB each. Nothing leaves your Mac."
                : "Apple Translation needs macOS 15.0 or later. Pick AI model below to translate via your configured LLM."
        case .llm:
            return "Sends the captured text to the AI model picked below. Faster on long passages, handles uncommon language pairs."
        }
    }

    @ViewBuilder
    private func routingPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            let grouped = Dictionary(grouping: modelStore.models, by: { $0.provider })
            ForEach(ModelProvider.allCases, id: \.self) { provider in
                if let models = grouped[provider], !models.isEmpty {
                    Section(provider.label) {
                        ForEach(models) { m in
                            Text(m.label).tag(m.id.uuidString)
                        }
                    }
                }
            }
            Section("Legacy") {
                Text("OpenRouter (default)").tag("openrouter")
                Text("Ollama (default)").tag("ollama")
            }
        }
    }
}

/// Compact one-row layout for a single hotkey binding. Lifted from the
/// `HotkeySettingsView` private struct so we can use the same shape here
/// without duplicating recorder glue.
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
