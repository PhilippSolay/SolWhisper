import SwiftUI

/// Settings panel for the Translate-from-screen feature.
/// Two sections live here:
///   - Engine: Apple (on-device, default on macOS 15+) or LLM (uses the
///     model picked in Settings → Models → Routing → Translation).
///   - Target language: the default the bubble opens with.
///
/// The translate hotkey is configured in Settings → Hotkey alongside the
/// other global shortcuts. The LLM model picker lives in Settings → Models
/// → Routing so all four routing roles (dictation cleanup, meeting cleanup,
/// meeting summary, translation) sit together.
struct TranslateSettingsView: View {

    @AppStorage(TranslationEngineKind.userDefaultsKey)
    private var engineRaw: String = TranslationEngineKind.current.rawValue
    @AppStorage("translateTargetLanguage")
    private var targetLanguage: String = TranslationLanguage.defaultTargetCode

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

        }
        .formStyle(.grouped)
        .navigationTitle("Translate")
    }

    private var engineFooter: String {
        switch TranslationEngineKind(rawValue: engineRaw) ?? .apple {
        case .apple:
            return supportsAppleTranslation
                ? "Apple's on-device translator. First use of a language pair prompts macOS to download the model — about 50 MB each. Nothing leaves your Mac."
                : "Apple Translation needs macOS 15.0 or later. Pick AI model to translate via your configured LLM."
        case .llm:
            return "Sends the captured text to the model picked in Settings → Models → Routing → Translation. Faster on long passages; handles uncommon language pairs."
        }
    }
}
