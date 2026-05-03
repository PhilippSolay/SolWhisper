import Foundation

/// Common interface for OpenRouter (cloud) and Ollama (local). Both providers
/// implement chat-completions semantics; the protocol normalizes their
/// surface so the post-processing pipeline can swap providers without
/// code changes.
protocol LLMClient: Sendable {
    /// Returns the assistant's text. Throws on transport / decoding error.
    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String
}

struct LLMMessage: Sendable, Codable {
    enum Role: String, Codable, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

enum LLMError: Error, LocalizedError {
    case missingApiKey(String)
    case http(status: Int, body: String)
    case decoding(String)
    case noChoices

    var errorDescription: String? {
        switch self {
        case .missingApiKey(let p):  return "Missing API key for \(p)"
        case .http(let s, let b):    return "HTTP \(s): \(b.prefix(200))"
        case .decoding(let m):       return "LLM response decoding failed: \(m)"
        case .noChoices:             return "LLM returned no choices"
        }
    }
}

/// Thin async wrapper around the existing callback-based OpenRouterClient.
/// Lets the post-processing pipeline call OpenRouter via the LLMClient
/// protocol without reworking the existing dictation polish path.
struct OpenRouterLLMClient: LLMClient {
    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        let apiKey = (try? KeychainStore.string(forKey: SecretsStore.Keys.openRouterApiKey)) ?? ""
        guard !apiKey.isEmpty else { throw LLMError.missingApiKey("openrouter") }

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw LLMError.http(status: 0, body: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json",   forHTTPHeaderField: "Content-Type")
        req.setValue("SolWhisper",         forHTTPHeaderField: "X-Title")

        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw LLMError.http(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decoding(String(data: data, encoding: .utf8) ?? "(no body)")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
