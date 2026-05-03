import Foundation

/// Direct Anthropic Messages API client (`https://api.anthropic.com/v1/messages`).
///
/// Differences from OpenAI-shape APIs:
/// - System prompt lives at the top level, not as a `system` role message.
/// - Auth header is `x-api-key`, not `Authorization: Bearer …`.
/// - Required `anthropic-version` header.
/// - Response shape is `content: [{type, text}]`, not `choices[0].message.content`.
struct AnthropicClient: LLMClient {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        let apiKey = (try? KeychainStore.string(
            forKey: ModelProvider.anthropic.apiKeyKeychainKey
        )) ?? ""
        guard !apiKey.isEmpty else { throw LLMError.missingApiKey("anthropic") }

        // Split system prompts out — Anthropic's API requires them at top level.
        let systemPrompt = messages.filter { $0.role == .system }
            .map(\.content).joined(separator: "\n\n")
        let chatMessages = messages.filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": chatMessages
        ]
        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey,                forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion,       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",    forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw LLMError.http(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = first["text"] as? String else {
            throw LLMError.decoding(String(data: data, encoding: .utf8) ?? "(no body)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
