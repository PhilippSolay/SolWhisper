import Foundation

class OpenRouterClient {

    func polish(text: String, completion: @escaping (String?) -> Void) {
        let apiKey = UserDefaults.standard.string(forKey: "openRouterApiKey") ?? ""
        let model  = UserDefaults.standard.string(forKey: "openRouterModel") ?? "anthropic/claude-haiku-4-5-20251001"

        guard !apiKey.isEmpty else {
            Task { @MainActor in
                DebugLog.shared.log(icon: "✨", label: "OpenRouter skipped", value: "no API key", ok: false)
            }
            completion(text)
            return
        }

        let watch = Stopwatch()
        Task { @MainActor in
            DebugLog.shared.log(icon: "✨", label: "OpenRouter request", value: model)
        }

        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)",   forHTTPHeaderField: "Authorization")
        request.setValue("application/json",    forHTTPHeaderField: "Content-Type")
        request.setValue("SolWhisper",          forHTTPHeaderField: "X-Title")

        let systemPrompt = """
        You are a transcription polisher. Clean up raw speech-to-text: remove filler words \
        (um, uh, like, you know), fix grammar and punctuation, keep meaning exactly the same. \
        Return ONLY the cleaned text, nothing else.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ],
            "max_tokens": 1000
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let ms = watch.elapsed

            if let error {
                Task { @MainActor in
                    DebugLog.shared.log(icon: "✨", label: "OpenRouter error", value: error.localizedDescription, ms: ms, ok: false)
                }
                DispatchQueue.main.async { completion(text) }
                return
            }

            guard let data,
                  let json     = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices  = json["choices"]  as? [[String: Any]],
                  let first    = choices.first,
                  let message  = first["message"] as? [String: Any],
                  let content  = message["content"] as? String else {

                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no data"
                Task { @MainActor in
                    DebugLog.shared.log(icon: "✨", label: "OpenRouter bad response", value: String(raw.prefix(120)), ms: ms, ok: false)
                }
                DispatchQueue.main.async { completion(text) }
                return
            }

            // Token usage
            var tokenInfo: LogEntry.TokenInfo?
            if let usage      = json["usage"]              as? [String: Any],
               let prompt     = usage["prompt_tokens"]     as? Int,
               let completion = usage["completion_tokens"] as? Int {
                tokenInfo = LogEntry.TokenInfo(prompt: prompt, completion: completion)
            }

            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                DebugLog.shared.log(icon: "✨", label: "OpenRouter done",
                                    value: "\"\(String(cleaned.prefix(60)))\"",
                                    ms: ms, tokens: tokenInfo)
            }
            DispatchQueue.main.async { completion(cleaned) }
        }.resume()
    }
}
