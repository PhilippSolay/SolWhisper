import Foundation

class DeepgramClient: NSObject {

    var onTranscript: ((String, Bool) -> Void)?

    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closeCompletion: ((String?) -> Void)?
    private var pendingFinal = ""

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func connect() {
        guard !apiKey.isEmpty else {
            print("Deepgram: no API key set. Go to Settings to add one.")
            return
        }

        // Deepgram Nova-3 streaming endpoint
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()

        receiveMessage()
    }

    func send(audioData: Data) {
        guard let webSocket = webSocket else { return }
        let message = URLSessionWebSocketTask.Message.data(audioData)
        webSocket.send(message) { error in
            if let error = error {
                print("Deepgram send error: \(error)")
            }
        }
    }

    func closeAndWait(completion: @escaping (String?) -> Void) {
        closeCompletion = completion
        // Send close message to Deepgram to flush final transcript
        webSocket?.send(.data(Data())) { _ in }
        webSocket?.sendCloseCode(.normalClosure, completionHandler: { _ in })

        // Fallback: complete after 2s if no final response
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if let completion = self?.closeCompletion {
                self?.closeCompletion = nil
                completion(self?.pendingFinal)
            }
        }
    }

    func disconnect() {
        closeCompletion = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleTranscriptJSON(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleTranscriptJSON(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage() // Continue listening

            case .failure(let error):
                print("Deepgram receive error: \(error)")
                if let completion = self.closeCompletion {
                    self.closeCompletion = nil
                    DispatchQueue.main.async {
                        completion(self.pendingFinal.isEmpty ? nil : self.pendingFinal)
                    }
                }
            }
        }
    }

    private func handleTranscriptJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = response["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first,
              let transcript = first["transcript"] as? String,
              !transcript.isEmpty else { return }

        let isFinal = (response["is_final"] as? Bool) ?? false

        DispatchQueue.main.async {
            self.onTranscript?(transcript, isFinal)
            if isFinal {
                self.pendingFinal += transcript + " "

                // If speech_final — Deepgram determined end of utterance
                if (response["speech_final"] as? Bool) == true {
                    if let completion = self.closeCompletion {
                        self.closeCompletion = nil
                        completion(self.pendingFinal.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
    }
}
