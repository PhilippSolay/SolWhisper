import Foundation
import Combine
import AVFoundation
import Speech

@MainActor
class TranscriptionController: ObservableObject {

    @Published var isRecording    = false
    @Published var isPaused       = false
    @Published var liveTranscript = ""
    @Published var audioLevel: Float = 0.0
    @Published var spectrumBins: [Float] = [Float](repeating: 0, count: AudioEngine.fftBinCount)

    // Deepgram path
    private var audioEngine:    AudioEngine?
    private var deepgramClient: DeepgramClient?
    /// Fallback accumulator for Deepgram is_final segments
    private var isFinalAccumulator = ""

    // Apple Speech path
    private var appleClient: AppleSpeechClient?

    // WhisperKit path
    private var whisperClient: WhisperKitClient?

    /// Backend locked at startRecording() to avoid mid-session UserDefaults changes
    private var activeBackend = "apple"

    // MARK: - Start

    func startRecording() {
        guard !isRecording else { return }

        activeBackend = UserDefaults.standard.string(forKey: "transcriptionBackend") ?? "apple"

        if activeBackend == "deepgram" {
            requestMicThen { [weak self] in self?.launchDeepgram() }
        } else if activeBackend == "whisperkit" {
            requestMicThen { [weak self] in self?.launchWhisperKit() }
        } else {
            requestMicThen { [weak self] in self?.requestSpeechAuthThen { self?.launchAppleSpeech() } }
        }
    }

    // MARK: - Stop

    func stopRecording(completion: @escaping (String?) -> Void) {
        guard isRecording else { completion(nil); return }
        isPaused = false
        audioEngine?.isPaused = false

        if activeBackend == "deepgram" {
            audioEngine?.stop()
            deepgramClient?.closeAndWait { [weak self] finalText in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRecording = false
                    let raw = finalText ?? self.isFinalAccumulator
                    self.finish(raw.trimmingCharacters(in: .whitespaces), completion: completion)
                }
            }
        } else if activeBackend == "whisperkit" {
            whisperClient?.stopAndFinalize { [weak self] finalText in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRecording = false
                    self.finish((finalText ?? "").trimmingCharacters(in: .whitespaces), completion: completion)
                }
            }
        } else {
            appleClient?.stopAndFinalize { [weak self] finalText in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRecording = false
                    self.finish((finalText ?? "").trimmingCharacters(in: .whitespaces), completion: completion)
                }
            }
        }
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        // Each backend has its own audio tap — forward the pause flag so the
        // tap drops buffers instead of feeding them to the recognizer.
        audioEngine?.isPaused = isPaused      // Deepgram path
        appleClient?.isPaused = isPaused      // Apple Speech path
        whisperClient?.isPaused = isPaused    // WhisperKit path
        if isPaused {
            audioLevel = 0
            spectrumBins = [Float](repeating: 0, count: AudioEngine.fftBinCount)
        }
        DebugLog.shared.log(icon: isPaused ? "⏸" : "▶︎",
                            label: isPaused ? "Dictation paused" : "Dictation resumed",
                            value: activeBackend)
    }

    func cancel() {
        audioEngine?.stop()
        deepgramClient?.disconnect()
        appleClient?.cancel()
        whisperClient?.cancel()
        isRecording        = false
        isPaused           = false
        liveTranscript     = ""
        isFinalAccumulator = ""
    }

    // MARK: - Deepgram launch

    private func launchDeepgram() {
        liveTranscript     = ""
        isFinalAccumulator = ""
        isRecording        = true

        let apiKey = UserDefaults.standard.string(forKey: "deepgramApiKey") ?? ""
        deepgramClient = DeepgramClient(apiKey: apiKey)

        deepgramClient?.onTranscript = { [weak self] text, isFinal in
            Task { @MainActor in
                self?.liveTranscript = text
                if isFinal { self?.isFinalAccumulator += text + " " }
            }
        }
        deepgramClient?.connect()

        audioEngine = AudioEngine()
        audioEngine?.onAudioData      = { [weak self] data  in self?.deepgramClient?.send(audioData: data) }
        audioEngine?.onLevelUpdate    = { [weak self] level in Task { @MainActor in self?.audioLevel = level } }
        audioEngine?.onSpectrumUpdate = { [weak self] bins in Task { @MainActor in self?.spectrumBins = bins } }

        do {
            try audioEngine?.start()
        } catch {
            DebugLog.shared.log(icon: "🎙", label: "AudioEngine failed", value: "\(error)", ok: false)
            isRecording = false
        }
    }

    // MARK: - WhisperKit launch (non-streaming, transcribe-on-stop)

    private func launchWhisperKit() {
        liveTranscript = ""
        isRecording    = true

        let model = UserDefaults.standard.string(forKey: "whisperKitModel") ?? WhisperKitClient.defaultModel
        let client = WhisperKitClient(model: model)
        whisperClient = client

        client.onTranscript    = { [weak self] text, _ in Task { @MainActor in self?.liveTranscript = text } }
        client.onLevelUpdate   = { [weak self] level in Task { @MainActor in self?.audioLevel = level } }
        client.onSpectrumUpdate = { [weak self] bins in Task { @MainActor in self?.spectrumBins = bins } }

        do {
            try client.start()
        } catch {
            DebugLog.shared.log(icon: "🟣", label: "WhisperKit failed", value: "\(error)", ok: false)
            isRecording = false
        }
    }

    // MARK: - Apple Speech launch

    private func launchAppleSpeech() {
        liveTranscript  = ""
        isRecording     = true

        appleClient = AppleSpeechClient()
        appleClient?.onTranscript    = { [weak self] text, _ in Task { @MainActor in self?.liveTranscript = text } }
        appleClient?.onLevelUpdate   = { [weak self] level  in Task { @MainActor in self?.audioLevel = level } }
        appleClient?.onSpectrumUpdate = { [weak self] bins  in Task { @MainActor in self?.spectrumBins = bins } }

        do {
            try appleClient?.start()
        } catch {
            DebugLog.shared.log(icon: "🍎", label: "Apple Speech failed", value: "\(error)", ok: false)
            isRecording = false
        }
    }

    // MARK: - Shared finish (LLM polish)

    private func finish(_ text: String, completion: @escaping (String?) -> Void) {
        guard !text.isEmpty else { completion(nil); return }

        if UserDefaults.standard.bool(forKey: "enableLLMPolish") {
            let polisher = OpenRouterClient()
            polisher.polish(text: text) { polished in completion(polished ?? text) }
        } else {
            completion(text)
        }
    }

    // MARK: - Permission helpers

    private func requestMicThen(action: @escaping () -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        DebugLog.shared.log(icon: "🎙", label: "Mic permission", value: "\(status.rawValue) (\(status == .authorized ? "granted" : "NOT granted"))", ok: status == .authorized)
        switch status {
        case .authorized:
            action()
        case .notDetermined:
            isRecording = true
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { action() } else { self.isRecording = false }
                }
            }
        default:
            DebugLog.shared.log(icon: "🎙", label: "Microphone access denied — re-grant in System Settings → Privacy → Microphone", ok: false)
        }
    }

    private func requestSpeechAuthThen(action: @escaping () -> Void) {
        let status = AppleSpeechClient.authorizationStatus
        switch status {
        case .authorized:
            action()
        case .notDetermined:
            AppleSpeechClient.requestAuthorization { granted in
                Task { @MainActor in
                    if granted { action() } else { self.isRecording = false }
                }
            }
        default:
            DebugLog.shared.log(icon: "🍎", label: "Speech recognition not authorized", ok: false)
            isRecording = false
        }
    }
}
