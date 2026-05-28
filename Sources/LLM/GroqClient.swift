import Foundation

/// Groq's OpenAI-compatible chat-completions endpoint
/// (`https://api.groq.com/openai/v1/chat/completions`). Same body shape
/// as OpenAI; different base URL and Keychain entry.
struct GroqClient: LLMClient {

    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// 5 minute ceiling. Groq itself is fast; the long ceiling is insurance
    /// against transient backend slowdowns on the largest models.
    static let requestTimeout: TimeInterval = 300

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        try await LLMRetry.run("groq.complete") {
            try await self.rawComplete(messages: messages,
                                        model: model,
                                        temperature: temperature,
                                        maxTokens: maxTokens)
        }
    }

    private func rawComplete(messages: [LLMMessage],
                              model: String,
                              temperature: Double,
                              maxTokens: Int) async throws -> String {
        let apiKey = (try? KeychainStore.string(
            forKey: ModelProvider.groq.apiKeyKeychainKey
        )) ?? ""
        guard !apiKey.isEmpty else { throw LLMError.missingApiKey("groq") }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)",  forHTTPHeaderField: "Authorization")
        req.setValue("application/json",   forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = Self.requestTimeout

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
