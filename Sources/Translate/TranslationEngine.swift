import Foundation
#if canImport(Translation)
import Translation
#endif

/// Engine-agnostic translation used by *headless* callers — i.e. the
/// voice-translate-dictation feature, which needs a translated string to paste
/// without showing a bubble.
///
/// This layer is additive: the existing Translate-from-screen bubble keeps its
/// own inline SwiftUI `translationTask` path in `TranslateResultBubble`. We do
/// not refactor that working code; we only add a programmatic entry point.
@MainActor
protocol TranslationEngine {
    /// Translate `text` into `targetCode` (BCP-47). `sourceCode` is an optional
    /// hint — `nil` means auto-detect the source language.
    func translate(text: String, sourceCode: String?, targetCode: String) async throws -> String
}

/// How ready a language is for a given engine, used to drive the settings hint
/// next to each language in the dropdown.
enum LanguageReadiness: Equatable, Sendable {
    case ready          // usable right now, no action needed
    case needsDownload  // supported but the on-device pack must download first
    case unsupported    // this engine can't translate into the language
    case modelDependent // LLM engine on a model whose coverage we can't verify
    case llmFallback    // Apple can't translate it; the AI model engine takes
                        // over automatically for this language (e.g. Farsi)

    /// Short annotation shown next to a language in settings. `nil` = no badge.
    var hint: String? {
        switch self {
        case .ready:          return nil
        case .needsDownload:  return "needs download"
        case .unsupported:    return "not available"
        case .modelDependent: return "depends on model"
        case .llmFallback:    return "via AI model"
        }
    }
}

/// Builds the headless engine for the user's chosen engine kind.
@MainActor
enum TranslationEngineFactory {
    static func make(_ kind: TranslationEngineKind) -> TranslationEngine {
        switch kind {
        case .apple:
            #if canImport(Translation)
            if #available(macOS 15.0, *) {
                return AppleTranslationEngine()
            }
            #endif
            // Apple framework unavailable on this OS — fall back to LLM so the
            // feature still works rather than dead-ending.
            return LLMVoiceTranslationEngine()
        case .llm:
            return LLMVoiceTranslationEngine()
        }
    }
}

/// Per-engine language availability. Drives the "needs download / LLM only"
/// hints shown next to languages in settings.
@MainActor
enum TranslationAvailability {

    /// Readiness of `targetCode` for `engine`.
    ///
    /// The Apple engine consults `LanguageAvailability` (since the user hasn't
    /// spoken yet when settings render, we approximate the source with the
    /// current UI locale language — good enough for a hint; the real pair is
    /// resolved at translate time with the detected source).
    ///
    /// The LLM engine has no per-model language metadata to query — coverage is
    /// model-dependent. We answer by *provider class* of the resolved
    /// translation model rather than a brittle per-language table.
    static func readiness(for targetCode: String,
                          engine: TranslationEngineKind) async -> LanguageReadiness {
        switch engine {
        case .llm:
            return llmReadiness()
        case .apple:
            #if canImport(Translation)
            if #available(macOS 15.0, *) {
                return await appleReadiness(for: targetCode)
            }
            #endif
            return .unsupported
        }
    }

    /// LLM coverage isn't enumerable per language, so we classify by the
    /// resolved translation model's provider:
    /// - no model / custom (unroutable) → `.unsupported`
    /// - local Ollama (varies by model size) → `.modelDependent`
    /// - frontier cloud providers → `.ready`
    private static func llmReadiness() -> LanguageReadiness {
        guard let resolved = LLMResolver.resolve(.translation) else { return .unsupported }
        switch resolved.providerLabel {
        case "ollama": return .modelDependent
        default:       return .ready
        }
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    private static func appleReadiness(for targetCode: String) async -> LanguageReadiness {
        let availability = LanguageAvailability()
        let source = Locale.Language(identifier: Locale.current.language.languageCode?.identifier ?? "en")
        let target = Locale.Language(identifier: targetCode)
        let status = await availability.status(from: source, to: target)
        switch status {
        case .installed:   return .ready
        case .supported:   return .needsDownload
        case .unsupported:
            // Apple will never offer this language (e.g. Farsi). The translate
            // paths auto-route it to the AI model engine when one is routable,
            // so surface that as the effective state instead of a dead end.
            return llmReadiness() == .ready ? .llmFallback : .unsupported
        @unknown default:  return .unsupported
        }
    }
    #endif
}

/// Headless adapter over `LLMTranslationEngine`. Returns just the translated
/// string; truncation/provider metadata is dropped (not needed for paste).
@MainActor
struct LLMVoiceTranslationEngine: TranslationEngine {
    func translate(text: String, sourceCode: String?, targetCode: String) async throws -> String {
        let output = try await LLMTranslationEngine().translate(
            text: text,
            sourceCode: sourceCode,
            targetCode: targetCode
        )
        return output.translated
    }
}

// MARK: - Pack download resolution (BUG 2)

/// Pure decision for *which* language pack to queue when Apple reports a pair as
/// `.supported` (supported, but at least one side's pack isn't downloaded).
/// `.supported` alone doesn't say which side is missing — the old code always
/// queued the target, so translating an uninstalled non-English source INTO
/// already-installed English deep-linked a useless English→English download and
/// the blocked translation could never be resolved. Given each side's install
/// state, return the code that actually needs downloading.
enum TranslationPackResolver {
    static func codeToDownload(sourceInstalled: Bool,
                               targetInstalled: Bool,
                               sourceCode: String,
                               targetCode: String) -> String {
        if !sourceInstalled { return sourceCode }
        if !targetInstalled { return targetCode }
        // Both look installed — `.supported` shouldn't have occurred. Prefer the
        // source (the target is usually English / already present).
        return sourceCode
    }
}

#if canImport(Translation)
/// Probes single-language install status via `LanguageAvailability`, then feeds
/// `TranslationPackResolver` to pick the missing pack. English is the anchor the
/// pack feature already assumes present (the download flow prepares `en → <lang>`
/// to fetch a pack), so it's the pivot for per-language probes.
@available(macOS 15.0, *)
enum ApplePackProbe {
    static let anchor = "en"

    /// True when `code`'s on-device pack appears installed. Probes `anchor → code`;
    /// `.installed` means both packs are present, so `code`'s is present. The
    /// anchor itself is treated as installed by convention.
    static func isInstalled(_ code: String,
                            availability: LanguageAvailability = LanguageAvailability()) async -> Bool {
        if TranslationLanguage.sameLanguage(code, anchor) { return true }
        let status = await availability.status(
            from: Locale.Language(identifier: anchor),
            to: Locale.Language(identifier: code))
        return status == .installed
    }

    /// Language code to queue for download when the pair came back `.supported`.
    /// Resolves each side's install status, then delegates the choice to the pure
    /// `TranslationPackResolver`.
    static func codeToDownload(source: String?,
                               target: String,
                               availability: LanguageAvailability = LanguageAvailability()) async -> String {
        let sourceCode = source ?? Locale.current.language.languageCode?.identifier ?? anchor
        let sourceInstalled = await isInstalled(sourceCode, availability: availability)
        let targetInstalled = await isInstalled(target, availability: availability)
        return TranslationPackResolver.codeToDownload(
            sourceInstalled: sourceInstalled,
            targetInstalled: targetInstalled,
            sourceCode: sourceCode,
            targetCode: target)
    }
}
#endif
