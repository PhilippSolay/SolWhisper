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

    /// Short annotation shown next to a language in settings. `nil` = no badge.
    var hint: String? {
        switch self {
        case .ready:          return nil
        case .needsDownload:  return "needs download"
        case .unsupported:    return "not available"
        case .modelDependent: return "depends on model"
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
        case .unsupported: return .unsupported
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
