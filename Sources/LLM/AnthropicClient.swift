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

    /// 5 minute ceiling — long-form summaries on Sonnet/Opus can take 1-3 min
    /// against the 60s URLSession default, which surfaces as "The request
    /// timed out." for users on long meetings.
    static let requestTimeout: TimeInterval = 300

    /// Char threshold above which we wrap the system prompt in a cacheable
    /// block. ≈1000 tokens, which clears Sonnet/Opus's 1024-token minimum
    /// cacheable size and skips wasted overhead on tiny dictation prompts.
    /// Haiku's 2048-token minimum means short prompts won't cache there
    /// either — Anthropic just no-ops the directive in that case.
    static let cacheMinChars = 4_000

    func complete(messages: [LLMMessage],
                  model: String,
                  temperature: Double,
                  maxTokens: Int) async throws -> String {
        try await LLMRetry.run("anthropic.complete") {
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
            // Long system prompts (skill packs) get wrapped in a cacheable
            // block so subsequent calls within the 5-minute TTL hit the
            // Anthropic prompt cache. Saves ~90% of input cost and cuts
            // time-to-first-token for the static skill prefix.
            if systemPrompt.count >= Self.cacheMinChars {
                body["system"] = [[
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]]
            } else {
                body["system"] = systemPrompt
            }
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey,                forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion,       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",    forHTTPHeaderField: "content-type")
        req.timeoutInterval = Self.requestTimeout
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

    /// Real SSE streaming. Same body shape as `complete` plus `stream: true`,
    /// and parses Anthropic's per-event format. Yields the `text_delta`
    /// contents from `content_block_delta` events; ignores housekeeping
    /// events (`message_start`, `ping`, `message_stop`, etc.).
    func stream(messages: [LLMMessage],
                model: String,
                temperature: Double,
                maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        LLMRetry.runStream("anthropic.stream") {
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
                    let apiKey = (try? KeychainStore.string(
                        forKey: ModelProvider.anthropic.apiKeyKeychainKey
                    )) ?? ""
                    guard !apiKey.isEmpty else { throw LLMError.missingApiKey("anthropic") }

                    let systemPrompt = messages.filter { $0.role == .system }
                        .map(\.content).joined(separator: "\n\n")
                    let chatMessages = messages.filter { $0.role != .system }
                        .map { ["role": $0.role.rawValue, "content": $0.content] }

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "temperature": temperature,
                        "messages": chatMessages,
                        "stream": true
                    ]
                    if !systemPrompt.isEmpty {
                        if systemPrompt.count >= Self.cacheMinChars {
                            body["system"] = [[
                                "type": "text",
                                "text": systemPrompt,
                                "cache_control": ["type": "ephemeral"]
                            ]]
                        } else {
                            body["system"] = systemPrompt
                        }
                    }

                    var req = URLRequest(url: Self.endpoint)
                    req.httpMethod = "POST"
                    req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
                    req.setValue(Self.apiVersion,    forHTTPHeaderField: "anthropic-version")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "accept")
                    req.timeoutInterval = Self.requestTimeout
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
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        let eventType = json["type"] as? String
                        if eventType == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           (delta["type"] as? String) == "text_delta",
                           let text = delta["text"] as? String,
                           !text.isEmpty {
                            continuation.yield(text)
                        } else if eventType == "message_stop" {
                            break
                        } else if eventType == "error",
                                  let err = json["error"] as? [String: Any],
                                  let msg = err["message"] as? String {
                            throw LLMError.http(status: 0, body: msg)
                        }
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
