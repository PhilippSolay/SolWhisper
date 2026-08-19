import Foundation

/// Configuration for the voice-translate feature (speak → transcribe →
/// translate → paste). Capture is delegated to the shared
/// `TranscriptionController` via `AppDelegate`, and translation runs through the
/// shared translation bubble/engine (`TranslationEngineKind.current`) — Voice
/// Translate has no engine of its own. This just holds the target-language
/// preference the bubble is seeded with.
@MainActor
final class VoiceTranslateController {

    static let targetLanguageDefaultsKey = "voiceTranslateTargetLanguage"

    /// The default target-language code the user picked in settings.
    var targetCode: String {
        UserDefaults.standard.string(forKey: Self.targetLanguageDefaultsKey)
            ?? TranslationLanguage.defaultTargetCode
    }
}
