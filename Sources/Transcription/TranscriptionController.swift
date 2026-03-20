import Foundation
import Combine

@MainActor
class TranscriptionController: ObservableObject {

    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var audioLevel: Float = 0.0

    private var audioEngine: AudioEngine?
    private var deepgramClient: DeepgramClient?
    private var completionHandler: ((String?) -> Void)?
    private var fullTranscript = ""

    func startRecording() {
        guard !isRecording else { return }

        fullTranscript = ""
        liveTranscript = ""
        isRecording = true

        let apiKey = UserDefaults.standard.string(forKey: "deepgramApiKey") ?? ""
        deepgramClient = DeepgramClient(apiKey: apiKey)

        deepgramClient?.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                self?.liveTranscript = text
                if isFinal {
                    self?.fullTranscript += text + " "
                }
            }
        }

        deepgramClient?.connect()

        audioEngine = AudioEngine()
        audioEngine?.onAudioData = { [weak self] data in
            self?.deepgramClient?.send(audioData: data)
        }
        audioEngine?.onLevelUpdate = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        do {
            try audioEngine?.start()
        } catch {
            print("Audio engine failed: \(error)")
            isRecording = false
        }
    }

    func stopRecording(completion: @escaping (String?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }

        completionHandler = completion
        audioEngine?.stop()

        deepgramClient?.closeAndWait { [weak self] finalText in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRecording = false

                let combined = (self.fullTranscript + (finalText ?? "")).trimmingCharacters(in: .whitespaces)

                if UserDefaults.standard.bool(forKey: "enableLLMPolish") {
                    let polisher = OpenRouterClient()
                    polisher.polish(text: combined) { polished in
                        completion(polished ?? combined)
                    }
                } else {
                    completion(combined.isEmpty ? nil : combined)
                }
            }
        }
    }

    func cancel() {
        audioEngine?.stop()
        deepgramClient?.disconnect()
        isRecording = false
        liveTranscript = ""
        fullTranscript = ""
    }
}
