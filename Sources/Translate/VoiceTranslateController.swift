import Foundation

/// Configuration + translation step for the voice-translate feature
/// (speak → transcribe → translate → paste).
///
/// Capture (mic → final transcript) is delegated to the shared
/// `TranscriptionController` through `AppDelegate`, so this controller stays
/// thin and testable: it just turns a final transcript into translated text
/// using the engine the user picked. Apple's on-device engine is the default
/// (Philipp: "Apple first"); the LLM engine is available via the same toggle.
@MainActor
final class VoiceTranslateController {

    static let engineDefaultsKey = "voiceTranslateEngine"
    static let targetLanguageDefaultsKey = "voiceTranslateTargetLanguage"

    /// The engine the user picked for voice-translate. Defaults to Apple.
    var engineKind: TranslationEngineKind {
        let raw = UserDefaults.standard.string(forKey: Self.engineDefaultsKey)
            ?? TranslationEngineKind.apple.rawValue
        return TranslationEngineKind(rawValue: raw) ?? .apple
    }

    /// The default target-language code the user picked in settings.
    var targetCode: String {
        UserDefaults.standard.string(forKey: Self.targetLanguageDefaultsKey)
            ?? TranslationLanguage.defaultTargetCode
    }

    /// Translate `transcript` into the configured target language. Returns the
    /// text to paste. An empty/whitespace transcript passes through unchanged.
    ///
    /// We detect the source language from the transcript and pass it through:
    /// Apple's `prepareTranslation()` throws "Unable to Translate" when the
    /// source is nil because it can't tell which language pair to prepare.
    func translate(_ transcript: String) async throws -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        let detectedSource = LanguageDetector.detect(trimmed)?.code

        // Nothing to do if we're already in the target language.
        if let detectedSource, TranslationLanguage.sameLanguage(detectedSource, targetCode) {
            return transcript
        }

        let engine = TranslationEngineFactory.make(engineKind)
        return try await engine.translate(
            text: trimmed,
            sourceCode: detectedSource,
            targetCode: targetCode
        )
    }
}
