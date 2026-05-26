import Foundation

/// Translates text via the LLM configured for the `translation` role in
/// Settings → Models → Routing. Used when:
/// - The user has explicitly picked an LLM engine in Translate settings, or
/// - The Apple Translation framework is unavailable (macOS < 14.4) or
///   doesn't ship the requested language pair.
///
/// The prompt is deliberately strict — translation only, no commentary,
/// preserve formatting. Temperature 0.0 for determinism.
@MainActor
struct LLMTranslationEngine {

    /// Soft cap on input length. Beyond this we truncate with an ellipsis
    /// so we don't blow past the model's max output tokens (and the user's
    /// wallet). 4000 chars ≈ 1000 tokens, comfortably fits Haiku/Flash budgets.
    static let inputCharLimit: Int = 4_000

    enum EngineError: Error, LocalizedError {
        case unresolvedRole
        case empty
        case emptyResponse(model: String)

        var errorDescription: String? {
            switch self {
            case .unresolvedRole:
                return "No model configured for translation. Pick one in Settings → Models → Routing."
            case .empty:
                return "Nothing to translate."
            case .emptyResponse(let model):
                return "\(model) returned an empty translation. Try again or pick a different model."
            }
        }
    }

    struct Output {
        let translated: String
        let providerLabel: String
        let modelID: String
        let truncated: Bool
    }

    /// `sourceCode` is informational only — for the prompt header. The model
    /// can detect source language itself; we just hint at it. `targetCode`
    /// drives the system prompt.
    func translate(text: String,
                   sourceCode: String?,
                   targetCode: String) async throws -> Output {

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.empty }

        guard let resolved = LLMResolver.resolve(.translation) else {
            throw EngineError.unresolvedRole
        }

        let (payload, truncated) = clip(trimmed)

        let targetName = TranslationLanguage.named(targetCode).label
        let sourceName = sourceCode.map { TranslationLanguage.named($0).label }

        let system: String
        if let sourceName {
            system = """
            You are a professional translator. Translate the user's text from \(sourceName) into \(targetName).
            Rules:
            - Output ONLY the translated text. No commentary, no preamble, no quotes around the result.
            - Preserve paragraph breaks, line breaks, bullet markers, numbers, code blocks, URLs, and emoji exactly.
            - Keep proper names, brand names, and code identifiers unchanged.
            - If the input is already in \(targetName), output it unchanged.
            """
        } else {
            system = """
            You are a professional translator. Auto-detect the source language and translate the user's text into \(targetName).
            Rules:
            - Output ONLY the translated text. No commentary, no preamble, no quotes around the result.
            - Preserve paragraph breaks, line breaks, bullet markers, numbers, code blocks, URLs, and emoji exactly.
            - Keep proper names, brand names, and code identifiers unchanged.
            - If the input is already in \(targetName), output it unchanged.
            """
        }

        let raw = try await resolved.client.complete(
            messages: [
                .init(role: .system, content: system),
                .init(role: .user,   content: payload)
            ],
            model: resolved.modelID,
            temperature: 0.0,
            maxTokens: 4_000
        )

        let cleaned = postProcess(raw)
        // Defensive: some models occasionally return whitespace or just the
        // closing punctuation when the prompt confuses them. Surface this as
        // an error so the bubble can offer a Retry rather than silently
        // copying an empty string to the user's clipboard.
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.emptyResponse(model: resolved.modelID)
        }

        return Output(
            translated: cleaned,
            providerLabel: resolved.providerLabel,
            modelID: resolved.modelID,
            truncated: truncated
        )
    }

    // MARK: - Helpers

    private func clip(_ text: String) -> (String, Bool) {
        guard text.count > Self.inputCharLimit else { return (text, false) }
        let idx = text.index(text.startIndex, offsetBy: Self.inputCharLimit)
        return (String(text[..<idx]) + "…", true)
    }

    /// Strip the model's most common politeness wrappers ("Translation:",
    /// surrounding quotes, trailing ellipses it added). Best-effort — the
    /// system prompt asks for none of these, but cheap defensive cleanup.
    private func postProcess(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Translation:", "Translated text:", "Translated:", "Here is the translation:"]
        for p in prefixes {
            if s.lowercased().hasPrefix(p.lowercased()) {
                s = String(s.dropFirst(p.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.count >= 2, let first = s.first, let last = s.last {
            let openers: Set<Character> = ["\"", "“", "'", "‘", "«"]
            let closers: Set<Character> = ["\"", "”", "'", "’", "»"]
            if openers.contains(first) && closers.contains(last) {
                s = String(s.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }
}
