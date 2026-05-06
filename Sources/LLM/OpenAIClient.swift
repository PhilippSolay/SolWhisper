import Foundation

/// Direct OpenAI API client (`https://api.openai.com/v1/chat/completions`).
/// Same chat-completions shape as OpenRouter — separate file because the
/// endpoint, base URL, and API-key Keychain entry differ.
struct OpenAIClient: LLMClient {

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        let apiKey = (try? KeychainStore.string(
            forKey: ModelProvider.openai.apiKeyKeychainKey
        )) ?? ""
        guard !apiKey.isEmpty else { throw LLMError.missingApiKey("openai") }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json",   forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": temperature
        ]
        // o-series reasoning models reject `max_tokens` and `temperature`;
        // they only accept `max_completion_tokens`. Detect by prefix.
        if model.hasPrefix("o1") || model.hasPrefix("o3") {
            body.removeValue(forKey: "temperature")
            body["max_completion_tokens"] = maxTokens
        } else {
            body["max_tokens"] = maxTokens
        }
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
