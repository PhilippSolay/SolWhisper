import Foundation

/// Local LLM via Ollama's HTTP API (default `http://localhost:11434`).
/// Ollama's `/api/chat` accepts the same role/content shape as OpenAI-style
/// providers, so we can keep the protocol surface uniform.
struct OllamaClient: LLMClient {
    let baseURL: URL

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
    }

    /// Probes `/api/tags` to confirm Ollama is reachable.
    /// Used by Settings to surface "Ollama not running" before submitting work.
    static func isAvailable(at baseURL: URL = URL(string: "http://localhost:11434")!) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": maxTokens
            ],
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LLMError.http(status: http.statusCode,
                                 body: String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.decoding(String(data: data, encoding: .utf8) ?? "(no body)")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
