import SwiftUI

/// Settings panel for the Voice Translate feature (speak → transcribe →
/// translate → paste). Mirrors `TranslateSettingsView`, but the default
/// target-language picker also shows a per-engine availability badge next to
/// each language — which languages actually work depends on the selected
/// engine (Apple downloads on-device packs; LLM coverage is model-dependent).
///
/// Apple's on-device engine is the default ("Apple first"); the voice-translate
/// hotkey itself is configured in Settings → Hotkey alongside the others.
struct VoiceTranslateSettingsView: View {

    @AppStorage(VoiceTranslateController.engineDefaultsKey)
    private var engineRaw: String = TranslationEngineKind.apple.rawValue
    @AppStorage(VoiceTranslateController.targetLanguageDefaultsKey)
    private var targetLanguage: String = TranslationLanguage.defaultTargetCode

    /// Readiness per curated language for the current engine. Recomputed
    /// whenever the engine changes (see `.task(id:)`).
    @State private var readiness: [String: LanguageReadiness] = [:]

    private var engineKind: TranslationEngineKind {
        TranslationEngineKind(rawValue: engineRaw) ?? .apple
    }

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
                Picker("Default language", selection: $targetLanguage) {
                    ForEach(TranslationLanguage.curated) { lang in
                        HStack {
                            Text(lang.label)
                            if let hint = readiness[lang.code]?.hint {
                                Spacer()
                                Text(hint).foregroundColor(.secondary)
                            }
                        }
                        .tag(lang.code)
                    }
                }
                if let hint = readiness[targetLanguage]?.hint {
                    LabeledContent("Availability") {
                        Text(hint).foregroundColor(.secondary)
                    }
                }
            } header: { Text("Default target language") } footer: {
                Text("Spoken words are transcribed, then translated into this language and pasted. Badges show availability for the selected engine.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Translate")
        .task(id: engineRaw) { await refreshReadiness() }
    }

    /// Recompute readiness for every curated language under the current engine.
    private func refreshReadiness() async {
        var result: [String: LanguageReadiness] = [:]
        for lang in TranslationLanguage.curated {
            result[lang.code] = await TranslationAvailability.readiness(
                for: lang.code, engine: engineKind
            )
        }
        readiness = result
    }

    private var engineFooter: String {
        switch engineKind {
        case .apple:
            return supportsAppleTranslation
                ? "Apple's on-device translator. First use of a language prompts macOS to download the model — about 50 MB each. Nothing leaves your Mac."
                : "Apple Translation needs macOS 15.0 or later. Pick AI model to translate via your configured LLM."
        case .llm:
            return "Uses the model picked in Settings → Models → Routing → Translation. Language coverage depends on the model — frontier cloud models cover all listed languages; small local models may not."
        }
    }
}
