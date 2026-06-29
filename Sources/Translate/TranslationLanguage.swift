import Foundation

/// Languages we expose in the target-language picker. Stored as BCP-47 codes.
/// Apple `Translation` framework accepts these directly; the LLM engine uses
/// the human-readable label in its prompt.
///
/// This single `curated` array is the source of truth for EVERY target-language
/// dropdown and the default-language settings across the app. Adding a language
/// is a one-line change here — append a `.init(code:label:)` entry and it shows
/// up everywhere automatically. Codes are BCP-47; the Apple engine accepts them
/// directly and the LLM engine uses the label in its prompt.
///
/// Availability differs by engine: the Apple on-device translator may need to
/// download a ~50 MB pack per pair (and not every language is offered), while
/// the LLM engine handles any entry with no download. See `TranslationEngine`.
struct TranslationLanguage: Hashable, Identifiable, Sendable {

    let code: String   // BCP-47, e.g. "en", "fr", "id", "es", "zh-Hans"
    let label: String  // Human-readable display name in the source UI locale

    var id: String { code }

    /// The curated picker entries. Order is intentional: English first
    /// (most common target), then the rest alphabetical by label for
    /// predictability. Append here to add a language everywhere at once.
    static let curated: [TranslationLanguage] = [
        .init(code: "en",      label: "English"),
        .init(code: "zh-Hans", label: "Chinese (Simplified)"),
        .init(code: "fa",      label: "Farsi"),
        .init(code: "fr",      label: "French"),
        .init(code: "de",      label: "German"),
        .init(code: "id",      label: "Indonesian"),
        .init(code: "it",      label: "Italian"),
        .init(code: "ja",      label: "Japanese"),
        .init(code: "ko",      label: "Korean"),
        .init(code: "ru",      label: "Russian"),
        .init(code: "es",      label: "Spanish")
    ]

    /// Default target shown the very first time the user opens the bubble.
    static let defaultTargetCode = "en"

    /// Looks up a curated entry by code. Falls back to a synthesized entry
    /// using `Locale.localizedString` so detected source languages outside
    /// the curated list still render with a real name in the source tag.
    static func named(_ code: String) -> TranslationLanguage {
        if let hit = curated.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            return hit
        }
        let normalized = code.lowercased()
        let display = Locale.current.localizedString(forLanguageCode: normalized)
                   ?? Locale.current.localizedString(forIdentifier: normalized)
                   ?? code.uppercased()
        return TranslationLanguage(code: code, label: display)
    }

    /// Loose equality used to short-circuit "source == target" translations.
    /// `"en"` and `"en-US"` should be treated as the same — we only compare
    /// the primary subtag.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        primarySubtag(a).caseInsensitiveCompare(primarySubtag(b)) == .orderedSame
    }

    private static func primarySubtag(_ code: String) -> String {
        // Keep `zh-Hans` vs `zh-Hant` distinct — they are different scripts
        // and translating between them is valid. Anything else collapses to
        // its primary subtag.
        let lower = code.lowercased()
        if lower.hasPrefix("zh-") { return lower }
        return String(code.split(separator: "-").first ?? Substring(code))
    }
}
