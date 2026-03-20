import Foundation

class OpenRouterClient {

    func polish(text: String, completion: @escaping (String?) -> Void) {
        let apiKey = UserDefaults.standard.string(forKey: "openRouterApiKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "openRouterModel") ?? "anthropic/claude-haiku-4-5-20251001"

        guard !apiKey.isEmpty else {
            completion(text)
            return
        }

        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SolWhisper", forHTTPHeaderField: "X-Title")

        let systemPrompt = """
        You are a transcription polisher. The user will provide raw speech-to-text output. \
        Your job is to:
        1. Remove filler words (um, uh, like, you know, etc.)
        2. Fix grammar and punctuation
        3. Keep the meaning exactly the same
        4. Return ONLY the cleaned text, nothing else
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1000
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                DispatchQueue.main.async { completion(text) }
                return
            }

            DispatchQueue.main.async { completion(content.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }.resume()
    }
}
