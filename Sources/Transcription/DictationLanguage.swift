import Foundation

/// A dictation input language the STT backends can transcribe. Drives the
/// tray "Input Language" submenu and the Languages settings pane.
///
/// The `id` is a full BCP-47 locale (`"es-ES"`) because Apple Speech needs
/// regional locales; the other backends derive their coarser codes from it.
/// Stored verbatim in UserDefaults under `defaultsKey`.
struct DictationLanguage: Identifiable, Hashable, Sendable {
    /// Full BCP-47 locale ID, e.g. `"es-ES"` — also the persisted value.
    let id: String
    /// User-facing name, e.g. `"Spanish (Spain)"`.
    let label: String
    /// Deepgram streaming `language` query value. Differs from the primary
    /// subtag where Deepgram has a regional model (`"es-419"`, `"fr-CA"`).
    let deepgramCode: String

    /// Locale handed to `SFSpeechRecognizer(locale:)`.
    var appleLocale: Locale { Locale(identifier: id) }

    /// Whisper decode-language token — bare primary subtag: `"es-ES"` → `"es"`.
    var whisperCode: String { String(id.prefix(while: { $0 != "-" })) }

    var isEnglish: Bool { whisperCode == "en" }
}

extension DictationLanguage {

    static let defaultsKey = "dictationLanguage"

    /// Used when nothing (or garbage) is stored — matches the pre-multilingual
    /// behavior where every backend was pinned to US English.
    static let fallback = DictationLanguage(
        id: "en-US", label: "English (US)", deepgramCode: "en-US")

    /// v1 catalog: European languages only. All space-delimited scripts, so
    /// the polish hallucination guard (whitespace word-ratio) stays valid —
    /// adding CJK requires reworking that guard first.
    static let curated: [DictationLanguage] = [
        fallback,
        DictationLanguage(id: "en-GB", label: "English (UK)",        deepgramCode: "en-GB"),
        DictationLanguage(id: "es-ES", label: "Spanish (Spain)",     deepgramCode: "es"),
        DictationLanguage(id: "es-MX", label: "Spanish (Mexico)",    deepgramCode: "es-419"),
        DictationLanguage(id: "fr-FR", label: "French (France)",     deepgramCode: "fr"),
        DictationLanguage(id: "fr-CA", label: "French (Canada)",     deepgramCode: "fr-CA"),
        DictationLanguage(id: "de-DE", label: "German",              deepgramCode: "de"),
        DictationLanguage(id: "it-IT", label: "Italian",             deepgramCode: "it"),
        DictationLanguage(id: "pt-BR", label: "Portuguese (Brazil)", deepgramCode: "pt-BR"),
        DictationLanguage(id: "nl-NL", label: "Dutch",               deepgramCode: "nl"),
    ]

    /// Curated entry for `id`, or `fallback` — never nil, so a stale or
    /// hand-edited stored value can't break menu building or recording start.
    static func named(_ id: String) -> DictationLanguage {
        curated.first { $0.id == id } ?? fallback
    }

    /// The user's chosen input language (tray menu / Languages pane).
    static var selected: DictationLanguage { selected(in: .standard) }

    static func selected(in defaults: UserDefaults) -> DictationLanguage {
        named(defaults.string(forKey: defaultsKey) ?? fallback.id)
    }
}
