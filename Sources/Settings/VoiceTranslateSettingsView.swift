import SwiftUI

/// Settings panel for the Voice Translate feature (speak → transcribe →
/// translate → paste). The default target-language picker shows a per-language
/// availability badge; which languages actually work depends on the shared
/// translation engine (Settings → Translate → Engine), which Voice Translate
/// uses too. The voice-translate hotkey is configured in Settings → Hotkey.
struct VoiceTranslateSettingsView: View {

    @AppStorage(VoiceTranslateController.targetLanguageDefaultsKey)
    private var targetLanguage: String = TranslationLanguage.defaultTargetCode

    /// Readiness per curated language for the engine Voice Translate actually
    /// uses — the shared translate engine. Recomputed on appear.
    @State private var readiness: [String: LanguageReadiness] = [:]

    /// Voice Translate routes through the shared translation engine, so the
    /// availability badges reflect that engine (there is no VT-specific engine).
    private var engineKind: TranslationEngineKind { .current }

    var body: some View {
        Form {
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
                Text("Spoken words are transcribed, then translated into this language and pasted. Badges show availability for your translation engine (Settings → Translate) — Voice Translate uses the same engine.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voice Translate")
        .task { await refreshReadiness() }
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
}
