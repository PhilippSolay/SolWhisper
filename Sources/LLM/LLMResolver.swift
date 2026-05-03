import Foundation

/// Resolves a routing role (dictation cleanup, meeting cleanup, meeting summary)
/// to a concrete `(LLMClient, modelID)` pair the post-processing pipeline can call.
///
/// Routing storage shape:
/// - Each role's UserDefault key (`dictationLLMProvider`, `cleanupLLMProvider`,
///   `summaryLLMProvider`) holds **either** a `ConfiguredModel.id` UUID string
///   (preferred path), **or** a legacy provider name like `"openrouter"` /
///   `"ollama"` (fallback for users upgrading from before Models Phase 2).
/// - The legacy path keeps reading `openRouterModel` / `summaryOpenRouterModel`
///   / `ollamaSummaryModel` UserDefaults so existing installs keep working.
///
/// Phase 2 supports direct API calls for **OpenRouter, Ollama, and Anthropic**.
/// OpenAI / Google / Groq are still routable via OpenRouter (use a
/// configured model with provider `.openrouter` and a model ID like
/// `openai/gpt-4o`); a future cleanup pass will add direct clients for those.
@MainActor
enum LLMResolver {

    enum Role: String {
        case dictation = "dictationLLMProvider"
        case cleanup   = "cleanupLLMProvider"
        case summary   = "summaryLLMProvider"
    }

    struct Resolved {
        let client: LLMClient
        let modelID: String
        /// Used for log labelling and SummaryGenerator's `provider` field.
        let providerLabel: String
    }

    /// Returns nil if the role cannot be resolved (no key, no models, etc.).
    static func resolve(_ role: Role) -> Resolved? {
        let raw = UserDefaults.standard.string(forKey: role.rawValue) ?? "openrouter"

        // Preferred path — UUID points to a ConfiguredModel.
        if let uuid = UUID(uuidString: raw),
           let model = ModelStore.shared.models.first(where: { $0.id == uuid }) {
            return resolveConfigured(model, role: role)
        }

        // Legacy fallback — provider name string.
        return resolveLegacy(provider: raw, role: role)
    }

    // MARK: - Configured-model path

    private static func resolveConfigured(_ model: ConfiguredModel, role: Role) -> Resolved? {
        switch model.provider {
        case .openrouter:
            return Resolved(client: OpenRouterLLMClient(),
                            modelID: model.modelID,
                            providerLabel: "openrouter")
        case .ollama:
            let baseURL = URL(string: UserDefaults.standard.string(forKey: "ollamaBaseURL")
                              ?? "http://localhost:11434")!
            return Resolved(client: OllamaClient(baseURL: baseURL),
                            modelID: model.modelID,
                            providerLabel: "ollama")
        case .anthropic:
            return Resolved(client: AnthropicClient(),
                            modelID: model.modelID,
                            providerLabel: "anthropic")
        case .openai, .google, .groq, .custom:
            // No direct client yet — silently fail back to OpenRouter if a
            // key is configured. Logged so the user sees why their pick
            // didn't apply.
            DebugLog.shared.log(icon: "🛣️", label: "Routing fallback",
                                value: "No direct \(model.provider.label) client; falling back to OpenRouter",
                                ok: false)
            _ = role
            return nil
        }
    }

    // MARK: - Legacy provider-name path

    private static func resolveLegacy(provider: String, role: Role) -> Resolved? {
        switch provider {
        case "ollama":
            let baseURL = URL(string: UserDefaults.standard.string(forKey: "ollamaBaseURL")
                              ?? "http://localhost:11434")!
            let model: String
            switch role {
            case .summary: model = UserDefaults.standard.string(forKey: "ollamaSummaryModel") ?? "llama3.2"
            default:       model = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
            }
            return Resolved(client: OllamaClient(baseURL: baseURL),
                            modelID: model,
                            providerLabel: "ollama")

        case "openrouter":
            let model: String
            switch role {
            case .summary:
                model = UserDefaults.standard.string(forKey: "summaryOpenRouterModel")
                      ?? "anthropic/claude-3-5-haiku"
            default:
                model = UserDefaults.standard.string(forKey: "openRouterModel")
                     ?? "anthropic/claude-3-5-haiku"
            }
            return Resolved(client: OpenRouterLLMClient(),
                            modelID: model,
                            providerLabel: "openrouter")

        default:
            return nil
        }
    }
}
