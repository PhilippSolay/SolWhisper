import Foundation
import NaturalLanguage

/// Detects the language of a piece of text using `NLLanguageRecognizer`.
/// Used to populate the source-language tag in the Translate bubble when
/// the user hasn't pinned a source manually.
///
/// We expose confidence so the UI can fall back to an `Auto ▾` picker when
/// the recognizer isn't sure — short OCR captures like "OK" or "next" can
/// match multiple languages and a confident-looking `[ENGLISH]` tag would
/// mislead the user.
enum LanguageDetector {

    struct Result {
        let code: String      // BCP-47 (e.g. "en", "zh-Hans")
        let confidence: Double  // 0…1, from NLLanguageRecognizer hypotheses
    }

    /// Minimum confidence to render the auto-detected language as a fixed
    /// tag rather than an overridable picker. Below this we let the user
    /// pick the source manually.
    static let confidenceThreshold: Double = 0.5

    /// Returns the best-guess language for `text`, or nil if the recognizer
    /// can't produce a hypothesis (empty text, unknown script).
    static func detect(_ text: String) -> Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let (lang, confidence) = hypotheses.first {
            return Result(code: bcp47(from: lang), confidence: confidence)
        }
        if let lang = recognizer.dominantLanguage {
            // dominantLanguage exists even when hypotheses dictionary is
            // empty for very short strings — give it a low confidence so
            // the UI knows to show the override picker.
            return Result(code: bcp47(from: lang), confidence: 0.0)
        }
        return nil
    }

    /// Maps `NLLanguage` to the BCP-47 codes our picker uses.
    /// `NLLanguage.rawValue` is already BCP-47 in most cases but Chinese
    /// is split into `zh-Hans` / `zh-Hant` and we want to honor that split.
    private static func bcp47(from lang: NLLanguage) -> String {
        switch lang {
        case .simplifiedChinese:  return "zh-Hans"
        case .traditionalChinese: return "zh-Hant"
        default:                   return lang.rawValue
        }
    }
}
