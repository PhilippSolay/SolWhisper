import Foundation

/// Google Gemini API client. Distinct from OpenAI/Anthropic shape:
/// - URL embeds the model name and the API key as a query param.
/// - Body uses `contents` / `parts` instead of `messages`.
/// - System prompt lives at top level under `systemInstruction`.
/// - Response is `candidates[].content.parts[].text`.
struct GoogleClient: LLMClient {

    static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        let apiKey = (try? KeychainStore.string(
            forKey: ModelProvider.google.apiKeyKeychainKey
        )) ?? ""
        guard !apiKey.isEmpty else { throw LLMError.missingApiKey("google") }

        guard let url = URL(string: "\(Self.baseURL)/\(model):generateContent?key=\(apiKey)") else {
            throw LLMError.http(status: 0, body: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Split out system prompts; merge into a single systemInstruction.
        let systemText = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        // Convert chat messages into Gemini's contents shape. Gemini uses
        // role names "user" and "model"; we map .assistant → "model".
        let chat = messages.compactMap { msg -> [String: Any]? in
            guard msg.role != .system else { return nil }
            let role = (msg.role == .assistant) ? "model" : "user"
            return [
                "role": role,
                "parts": [["text": msg.content]]
            ]
        }

        var body: [String: Any] = [
            "contents": chat,
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        if !systemText.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemText]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw LLMError.http(status: http.statusCode, body: body)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.decoding(String(data: data, encoding: .utf8) ?? "(no body)")
        }
        // Concatenate all text parts; Gemini may split a response into multiple.
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
