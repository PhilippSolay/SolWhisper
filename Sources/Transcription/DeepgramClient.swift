import Foundation

/// Deepgram v2 streaming client.
///
/// v2 differences from v1:
/// - Endpoint: wss://api.deepgram.com/v2/listen
/// - Audio sent as **base64-encoded text** WebSocket frames (not binary)
/// - Server responses are **base64-encoded JSON** text frames
/// - Response events: StartOfTurn, transcript payloads, EndOfTurn
class DeepgramClient: NSObject {

    var onTranscript: ((String, Bool) -> Void)?

    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closeCompletion: ((String?) -> Void)?
    private var pendingTranscript = ""

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func connect() {
        guard !apiKey.isEmpty else {
            print("Deepgram: no API key set — open Settings to add one.")
            return
        }

        var components = URLComponents(string: "wss://api.deepgram.com/v2/listen")!
        components.queryItems = [
            URLQueryItem(name: "model",            value: "flux-general-en"),
            URLQueryItem(name: "encoding",         value: "linear16"),
            URLQueryItem(name: "sample_rate",      value: "16000"),
            URLQueryItem(name: "eot_threshold",    value: "0.7"),
            URLQueryItem(name: "eot_timeout_ms",   value: "5000"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        session = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()

        receiveMessage()
    }

    /// Send PCM16 audio — v2 requires base64-encoded text frames.
    func send(audioData: Data) {
        guard let webSocket = webSocket else { return }
        let base64 = audioData.base64EncodedString()
        webSocket.send(.string(base64)) { error in
            if let error = error {
                print("Deepgram send error: \(error)")
            }
        }
    }

    func closeAndWait(completion: @escaping (String?) -> Void) {
        closeCompletion = completion
        webSocket?.cancel(with: .normalClosure, reason: nil)

        // Fallback timeout in case EndOfTurn never arrives
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, let cb = self.closeCompletion else { return }
            self.closeCompletion = nil
            cb(self.pendingTranscript.isEmpty ? nil : self.pendingTranscript)
        }
    }

    func disconnect() {
        closeCompletion = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    // MARK: - Private

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let raw):
                    self.handleFrame(raw)
                case .data(let data):
                    if let raw = String(data: data, encoding: .utf8) {
                        self.handleFrame(raw)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                print("Deepgram receive error: \(error)")
                if let cb = self.closeCompletion {
                    self.closeCompletion = nil
                    DispatchQueue.main.async {
                        cb(self.pendingTranscript.isEmpty ? nil : self.pendingTranscript)
                    }
                }
            }
        }
    }

    /// v2 frames are base64-encoded JSON.
    private func handleFrame(_ raw: String) {
        // Decode base64 → JSON string
        let jsonString: String
        if let decoded = Data(base64Encoded: raw),
           let str = String(data: decoded, encoding: .utf8) {
            jsonString = str
        } else {
            // Already plain JSON (fallback / dev relay)
            jsonString = raw
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let event = json["event"] as? String

        if let transcript = json["transcript"] as? String, !transcript.isEmpty {
            let isFinal = event == "EndOfTurn"
            DispatchQueue.main.async {
                self.onTranscript?(transcript, isFinal)
                self.pendingTranscript += transcript + " "
            }
        }

        if event == "EndOfTurn" {
            DispatchQueue.main.async {
                if let cb = self.closeCompletion {
                    self.closeCompletion = nil
                    cb(self.pendingTranscript.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }
}
