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

    /// Streams the assistant's text in chunks as the model generates it.
    /// Default implementation wraps `complete` and yields the full text
    /// as a single chunk — concrete clients should override with real
    /// SSE for long-form generation where the per-chunk activity also
    /// keeps the connection alive past URLSession's default timeout.
    func stream(messages: [LLMMessage],
                model: String,
                temperature: Double,
                maxTokens: Int) -> AsyncThrowingStream<String, Error>
}

extension LLMClient {
    func stream(messages: [LLMMessage],
                model: String,
                temperature: Double,
                maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.complete(
                        messages: messages,
                        model: model,
                        temperature: temperature,
                        maxTokens: maxTokens
                    )
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
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
        case .missingApiKey(let p):
            return "Missing API key for \(p)"
        case .http(let s, let b):
            return Self.friendlyHTTPMessage(status: s, body: b)
        case .decoding(let m):
            return "LLM response decoding failed: \(String(m.prefix(160)))"
        case .noChoices:
            return "LLM returned no choices"
        }
    }

    /// Human-readable rendering for HTTP failures. Detects HTML bodies
    /// (e.g. "<html>…502 Bad Gateway…</html>" from edge proxies) and
    /// substitutes a single-sentence hint so the UI doesn't show a wall
    /// of markup in red. Falls back to a trimmed body for JSON errors
    /// where the provider's message is actionable.
    private static func friendlyHTTPMessage(status: Int, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeHTML = trimmed.hasPrefix("<") || trimmed.lowercased().contains("<html")
        let phase: String
        switch status {
        case 408, 504:        phase = "The provider took too long to respond."
        case 429:             phase = "The provider rate-limited the request."
        case 500, 502, 503:   phase = "The provider had a server hiccup."
        case 401, 403:        phase = "The provider rejected the request (check your API key)."
        case 404:             phase = "The provider couldn't find that model or endpoint."
        case 0:               phase = "Network error."
        default:              phase = "Provider returned HTTP \(status)."
        }

        if looksLikeHTML || trimmed.isEmpty {
            return status >= 500
                ? "\(phase) Auto-retried but still failed — try again in a moment."
                : phase
        }
        // JSON body — keep a short excerpt so error messages from the
        // provider (model unavailable, content policy, etc.) are visible.
        return "\(phase) \(trimmed.prefix(180))"
    }
}

/// Thin async wrapper around the existing callback-based OpenRouterClient.
/// Lets the post-processing pipeline call OpenRouter via the LLMClient
/// protocol without reworking the existing dictation polish path.
struct OpenRouterLLMClient: LLMClient {

    /// 5 minute ceiling — OpenRouter routes to providers whose long-form
    /// generations regularly run 60-180s on big meeting summaries.
    static let requestTimeout: TimeInterval = 300

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        try await LLMRetry.run("openrouter.complete") {
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

    /// Real SSE streaming for OpenRouter. The per-chunk activity keeps the
    /// URLSession connection alive even on multi-minute generations and
    /// lets callers surface progress instead of blocking on a single big
    /// response. Parses OpenAI-shape `choices[0].delta.content` deltas.
    func stream(messages: [LLMMessage],
                model: String,
                temperature: Double,
                maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        LLMRetry.runStream("openrouter.stream") {
            self.rawStream(messages: messages,
                            model: model,
                            temperature: temperature,
                            maxTokens: maxTokens)
        }
    }

    private func rawStream(messages: [LLMMessage],
                            model: String,
                            temperature: Double,
                            maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let apiKey = (try? KeychainStore.string(forKey: SecretsStore.Keys.openRouterApiKey)) ?? ""
                    guard !apiKey.isEmpty else { throw LLMError.missingApiKey("openrouter") }

                    guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
                        throw LLMError.http(status: 0, body: "bad url")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
                    req.setValue("SolWhisper",        forHTTPHeaderField: "X-Title")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = Self.requestTimeout

                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                        "max_tokens": maxTokens,
                        "temperature": temperature,
                        "stream": true
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                        var bodyData = Data()
                        for try await byte in bytes { bodyData.append(byte) }
                        throw LLMError.http(status: http.statusCode,
                                            body: String(data: bodyData, encoding: .utf8) ?? "")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let chunk = delta["content"] as? String,
                              !chunk.isEmpty else { continue }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
