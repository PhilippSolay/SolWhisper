import Foundation
import Speech

/// Answers "can the active STT backend dictate this language right now?"
/// for the tray submenu and the Languages settings pane.
///
/// Deliberately synchronous — the tray menu is rebuilt inside
/// `menuWillOpen`, which cannot await. Reuses the translate feature's
/// `LanguageReadiness` so both panes speak the same status vocabulary.
enum DictationLanguageAvailability {

    /// Readiness of `language` on `backend` (a `transcriptionBackend` value).
    ///
    /// - `"whisperkit"`: judged against the model the dictation picker has
    ///   selected (`whisperKitModel`) — a downloaded-but-unselected
    ///   multilingual model doesn't make Spanish work at record time, so it
    ///   doesn't count as ready.
    /// - `"deepgram"`: cloud — every curated language is always ready.
    /// - `"apple"` and anything else (incl. the "parakeet" placeholder, which
    ///   falls back to Apple Speech at launch): on-device pack probe.
    static func readiness(
        for language: DictationLanguage,
        backend: String,
        defaults: UserDefaults = .standard,
        modelsRoot: URL? = nil
    ) -> LanguageReadiness {
        switch backend {
        case "deepgram":   return .ready
        case "whisperkit": return whisperKitReadiness(for: language,
                                                      defaults: defaults,
                                                      modelsRoot: modelsRoot)
        default:           return appleReadiness(for: language)
        }
    }

    // MARK: - Apple Speech

    /// On-device recognition requires the macOS dictation pack for the locale
    /// (System Settings → Keyboard → Dictation). Server recognition is not an
    /// acceptable fallback for dictation — it caps requests at ~1 minute and
    /// would break the "audio never leaves this Mac" promise — so a missing
    /// pack reads as `.needsDownload`, not "works with caveats".
    private static func appleReadiness(for language: DictationLanguage) -> LanguageReadiness {
        guard let recognizer = SFSpeechRecognizer(locale: language.appleLocale) else {
            return .unsupported
        }
        return recognizer.supportsOnDeviceRecognition ? .ready : .needsDownload
    }

    // MARK: - WhisperKit

    private static func whisperKitReadiness(
        for language: DictationLanguage,
        defaults: UserDefaults,
        modelsRoot: URL?
    ) -> LanguageReadiness {
        let model = defaults.string(forKey: "whisperKitModel") ?? WhisperKitClient.defaultModel
        guard WhisperKitClient.isModelDownloaded(model, in: modelsRoot) else {
            return .needsDownload
        }
        if language.isEnglish { return .ready }
        // ".en" variants are English-only decode models — they cannot emit
        // any other language no matter what token we prefill.
        return model.hasSuffix(".en") ? .needsDownload : .ready
    }
}
