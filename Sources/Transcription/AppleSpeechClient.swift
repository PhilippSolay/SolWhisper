import Speech
import AVFoundation
import Accelerate

/// On-device / Apple-server speech recognition via SFSpeechRecognizer.
/// Manages its own AVAudioEngine — no Deepgram API key needed.
class AppleSpeechClient {

    var onTranscript:    ((String, Bool) -> Void)?
    var onLevelUpdate:   ((Float) -> Void)?
    var onSpectrumUpdate: (([Float]) -> Void)?

    private let recognizer  = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var task:        SFSpeechRecognitionTask?
    private var request:     SFSpeechAudioBufferRecognitionRequest?
    private let engine       = AVAudioEngine()
    private var finalCB:     ((String?) -> Void)?
    private var fallback:    DispatchWorkItem?
    private var latestText   = ""
    private var watch:       Stopwatch?
    private var firstLogged  = false
    /// When true, the audio tap drops buffers instead of feeding them to the
    /// recognizer. The pill UI's pause hotkey flips this; resuming continues
    /// transcription on the existing task without restarting.
    var isPaused = false

    // FFT state
    private let fftSize = 1024
    private var fftSetup: vDSP_DFT_Setup?
    private var fftWindow = [Float]()
    private var fftAccum  = [Float](repeating: 0, count: AudioEngine.fftBinCount)
    private var nativeSampleRate: Double = 48000

    // MARK: - Authorization

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // MARK: - Start

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw AppleSpeechError.unavailable
        }

        watch = Stopwatch()
        firstLogged = false
        latestText  = ""

        // Setup FFT
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftAccum = [Float](repeating: 0, count: AudioEngine.fftBinCount)

        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎", label: "Apple Speech starting", value: "on-device · en-US")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) { req.addsPunctuation = true }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }

        // Honor the user's preferred mic device before reading the format.
        PreferredInputDevice.applyToInputNode(engine)
        let input  = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        nativeSampleRate = format.sampleRate

        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎", label: "Audio format",
                                value: "\(Int(format.sampleRate))Hz \(format.channelCount)ch")
        }

        var bufferCount = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self = self else { return }
            // Pause hotkey drops buffers — the recognizer keeps its task open
            // but receives no new audio, so the live transcript stays frozen
            // at the last partial.
            if self.isPaused { return }
            self.request?.append(buf)
            self.emitLevel(buf)
            self.emitSpectrum(buf)
            // Log first buffer to confirm mic is delivering audio
            bufferCount += 1
            if bufferCount == 10 {
                let hasData = buf.floatChannelData != nil && buf.frameLength > 0
                Task { @MainActor in
                    DebugLog.shared.log(icon: "🍎", label: "Audio flowing",
                                        value: "frames=\(buf.frameLength) hasData=\(hasData)",
                                        ok: hasData)
                }
            }
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: - Stop

    func stopAndFinalize(completion: @escaping (String?) -> Void) {
        finalCB = completion
        request?.endAudio()

        let snap = latestText
        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎", label: "Apple Speech stop", value: snap.isEmpty ? "…" : "\"\(String(snap.prefix(60)))\"")
        }

        // 3-second fallback in case isFinal never arrives
        let work = DispatchWorkItem { [weak self] in
            guard let self, let cb = self.finalCB else { return }
            self.finalCB = nil
            let t = self.latestText
            Task { @MainActor in
                DebugLog.shared.log(icon: "🍎", label: "Apple Speech fallback",
                                    value: t.isEmpty ? "empty" : "\"\(t)\"", ok: !t.isEmpty)
            }
            cb(t.isEmpty ? nil : t)
        }
        fallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func cancel() {
        fallback?.cancel()
        finalCB = nil
        tearDown()
    }

    // MARK: - Private

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🍎", label: "Apple Speech error",
                                    value: error.localizedDescription, ok: false)
            }
        }
        guard let result else { return }

        let text    = result.bestTranscription.formattedString
        let isFinal = result.isFinal

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if !self.firstLogged && !text.isEmpty {
                self.firstLogged = true
                let ms = self.watch?.elapsed
                Task { @MainActor in
                    DebugLog.shared.log(icon: "🍎", label: "Apple Speech first word",
                                        value: "\"\(text)\"", ms: ms)
                }
            }

            self.latestText = text
            self.onTranscript?(text, isFinal)

            if isFinal {
                Task { @MainActor in
                    let ms = self.watch?.elapsed
                    DebugLog.shared.log(icon: "🍎", label: "Apple Speech final",
                                        value: "\"\(String(text.prefix(80)))\"", ms: ms)
                }
                self.fallback?.cancel()
                if let cb = self.finalCB {
                    self.finalCB = nil
                    cb(text.isEmpty ? nil : text)
                }
                self.tearDown()
            }
        }
    }

    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task     = nil
        request  = nil
        fftSetup = nil
        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: AudioEngine.fftBinCount))
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { let s = data[0][i]; sum += s * s }
        let rms   = sqrt(sum / Float(n))
        let level = min(rms * 8, 1.0)
        onLevelUpdate?(level)
    }

    private func emitSpectrum(_ buffer: AVAudioPCMBuffer) {
        guard let setup = fftSetup,
              let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let count = min(frameCount, fftSize)

        var windowed = [Float](repeating: 0, count: fftSize)
        for i in 0..<count { windowed[i] = floatData[0][i] * fftWindow[i] }

        var realIn  = windowed
        var imagIn  = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)

        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        let halfN = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }

        var maxMag: Float = 0
        vDSP_maxv(magnitudes, 1, &maxMag, vDSP_Length(halfN))
        if maxMag > 0.001 {
            var scale = 1.0 / maxMag
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))
        }

        // Only 300 Hz – 3000 Hz (speech range)
        let binCount  = AudioEngine.fftBinCount
        let hzPerBin  = Float(nativeSampleRate) / Float(fftSize)
        let loIdx     = max(0, Int(300.0 / hzPerBin))
        let hiIdx     = min(halfN - 1, Int(3000.0 / hzPerBin))
        let rangeLen  = Float(max(1, hiIdx - loIdx))

        var bins = [Float](repeating: 0, count: binCount)
        for b in 0..<binCount {
            let fLo = Float(loIdx) + pow(Float(b)     / Float(binCount), 1.6) * rangeLen
            let fHi = Float(loIdx) + pow(Float(b + 1) / Float(binCount), 1.6) * rangeLen
            let lo  = max(loIdx, Int(fLo))
            let hi  = min(hiIdx, max(lo + 1, Int(fHi)))
            var sum: Float = 0
            for j in lo..<hi { sum += magnitudes[j] }
            bins[b] = sum / Float(max(1, hi - lo))
        }

        let smooth: Float = 0.3
        for i in 0..<binCount {
            fftAccum[i] = fftAccum[i] * smooth + bins[i] * (1 - smooth)
        }

        onSpectrumUpdate?(fftAccum)
    }
}

enum AppleSpeechError: Error {
    case unavailable
}
