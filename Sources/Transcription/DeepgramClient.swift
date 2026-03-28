import Foundation

/// Deepgram v1 streaming client using nova-3.
///
/// Protocol:
/// - Audio sent as raw binary PCM16 frames
/// - Responses are plain JSON
/// - Close: send empty binary frame → wait for speech_final → complete
class DeepgramClient: NSObject {

    var onTranscript: ((String, Bool) -> Void)?

    private let apiKey: String
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closeCompletion: ((String?) -> Void)?
    private var accumulatedTranscript = ""
    private var fallbackTimer: DispatchWorkItem?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    // MARK: - Connect

    func connect() {
        guard !apiKey.isEmpty else {
            print("Deepgram: no API key — open Settings.")
            return
        }

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model",           value: "nova-3"),
            URLQueryItem(name: "language",        value: "en-US"),
            URLQueryItem(name: "encoding",        value: "linear16"),
            URLQueryItem(name: "sample_rate",     value: "16000"),
            URLQueryItem(name: "channels",        value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format",    value: "true"),
            URLQueryItem(name: "endpointing",     value: "300"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        session   = URLSession(configuration: .default)
        webSocket = session?.webSocketTask(with: request)
        webSocket?.resume()

        print("Deepgram: connecting to \(components.url!)")
        receiveLoop()
    }

    // MARK: - Send audio

    /// Send raw PCM16 audio as binary frame.
    func send(audioData: Data) {
        webSocket?.send(.data(audioData)) { error in
            if let error { print("Deepgram send error: \(error)") }
        }
    }

    // MARK: - Close

    /// Signal end-of-stream, wait for speech_final, then call completion.
    func closeAndWait(completion: @escaping (String?) -> Void) {
        closeCompletion = completion

        // Send zero-byte binary frame — tells Deepgram to flush & finalize
        webSocket?.send(.data(Data())) { _ in }

        // Fallback: if speech_final never arrives, complete after 4s
        let work = DispatchWorkItem { [weak self] in
            guard let self, let cb = self.closeCompletion else { return }
            print("Deepgram: fallback timeout — returning accumulated transcript")
            self.closeCompletion = nil
            let text = self.accumulatedTranscript.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async { cb(text.isEmpty ? nil : text) }
        }
        fallbackTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func disconnect() {
        fallbackTimer?.cancel()
        closeCompletion = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text): self.handleJSON(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handleJSON(text) }
                @unknown default: break
                }
                self.receiveLoop()
            case .failure(let error):
                print("Deepgram receive error: \(error)")
                // Socket closed — fire completion with whatever we have
                self.fallbackTimer?.cancel()
                if let cb = self.closeCompletion {
                    self.closeCompletion = nil
                    let text = self.accumulatedTranscript.trimmingCharacters(in: .whitespaces)
                    DispatchQueue.main.async { cb(text.isEmpty ? nil : text) }
                }
            }
        }
    }

    // MARK: - Parse response

    private func handleJSON(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Extract transcript from channel.alternatives[0].transcript
        guard let channel   = json["channel"]      as? [String: Any],
              let alts      = channel["alternatives"] as? [[String: Any]],
              let first     = alts.first,
              let transcript = first["transcript"]  as? String,
              !transcript.isEmpty else { return }

        let isFinal    = (json["is_final"]    as? Bool) ?? false
        let speechFinal = (json["speech_final"] as? Bool) ?? false

        print("Deepgram ← is_final=\(isFinal) speech_final=\(speechFinal): \"\(transcript)\"")

        DispatchQueue.main.async {
            self.onTranscript?(transcript, isFinal)
            if isFinal {
                self.accumulatedTranscript += transcript + " "
            }
            if speechFinal, let cb = self.closeCompletion {
                self.fallbackTimer?.cancel()
                self.closeCompletion = nil
                let text = self.accumulatedTranscript.trimmingCharacters(in: .whitespaces)
                cb(text.isEmpty ? nil : text)
            }
        }
    }
}
