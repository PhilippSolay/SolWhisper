import Speech
import AVFoundation
import Accelerate

/// On-device / Apple-server speech recognition via SFSpeechRecognizer.
/// Manages its own AVAudioEngine — no Deepgram API key needed.
class AppleSpeechClient {

    var onTranscript:    ((String, Bool) -> Void)?
    var onLevelUpdate:   ((Float) -> Void)?
    var onSpectrumUpdate: (([Float]) -> Void)?
    /// Fired when recognition is dead before producing any text and no retry
    /// is left (e.g. Siri + Dictation disabled system-wide). The message is
    /// user-facing; the owner should tear the session down and surface it.
    var onFatalError:    ((String) -> Void)?

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

    // On-device fallback state. `supportsOnDeviceRecognition` reports model
    // capability, NOT asset presence — with Siri + Dictation off, a forced
    // on-device request dies instantly with kAFAssistantErrorDomain 1700
    // ("Siri and Dictation are disabled"). When that happens before any result,
    // we retry once via Apple's servers, replaying the audio captured so far.
    private var usedOnDevice   = false
    private var didServerRetry = false
    private var sawResult      = false
    private var isTearingDown  = false

    // Early-audio stash for the retry replay. Written from the audio tap
    // thread, drained on main — guarded by `stashLock`. Capped so a session
    // that never errors doesn't accumulate forever (cleared on first result).
    private let stashLock = NSLock()
    private var stashedBuffers: [AVAudioPCMBuffer] = []
    private var isStashing = true
    private static let maxStashedBuffers = 512   // ~12 s of 1024-frame taps

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
        firstLogged    = false
        latestText     = ""
        usedOnDevice   = recognizer.supportsOnDeviceRecognition
        didServerRetry = false
        sawResult      = false
        isTearingDown  = false
        stashLock.lock()
        stashedBuffers = []
        isStashing     = true
        stashLock.unlock()

        // Setup FFT
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftAccum = [Float](repeating: 0, count: AudioEngine.fftBinCount)

        let mode = usedOnDevice ? "on-device" : "server"
        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎", label: "Apple Speech starting", value: "\(mode) · en-US")
        }

        // Prefer on-device recognition when the model supports it so audio never
        // leaves the Mac — matching the onboarding/Info.plist privacy promise.
        // If the on-device path fails before producing anything, handleResult
        // retries once via Apple's servers rather than dictating into the void.
        let req = makeRequest(onDevice: usedOnDevice)
        stashLock.lock()
        request = req
        stashLock.unlock()

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
            // Snapshot under the lock: retryViaServer swaps `request` from the
            // main thread mid-session; an unsynchronized read here could use a
            // deallocating object.
            self.stashLock.lock()
            let req = self.request
            self.stashLock.unlock()
            req?.append(buf)
            self.stashForReplay(buf)
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

        // 3-second fallback in case isFinal never arrives. We MUST tear
        // down the engine here too — otherwise the audio unit keeps
        // holding the mic device open and macOS shows the orange
        // microphone indicator forever.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let cb = self.finalCB else { return }
            self.finalCB = nil
            let t = self.latestText
            Task { @MainActor in
                DebugLog.shared.log(icon: "🍎", label: "Apple Speech fallback",
                                    value: t.isEmpty ? "empty" : "\"\(t)\"", ok: !t.isEmpty)
            }
            self.tearDown()
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
            let nsError = error as NSError
            // Hop to main before touching state — `isTearingDown` and the
            // recovery path are main-thread-owned; this callback isn't.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isTearingDown {
                    Task { @MainActor in
                        DebugLog.shared.log(icon: "🍎", label: "Apple Speech error",
                                            value: nsError.localizedDescription, ok: false)
                    }
                }
                self.recoverFromEarlyFailure(nsError)
            }
        }
        guard let result else { return }

        let text    = result.bestTranscription.formattedString
        let isFinal = result.isFinal

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if !self.sawResult {
                // Recognition is alive — the retry stash is no longer needed.
                self.sawResult = true
                self.stashLock.lock()
                self.isStashing = false
                self.stashedBuffers = []
                self.stashLock.unlock()
            }

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

    /// Recognizer died before producing any text. First option: if we forced
    /// on-device, retry once via Apple's servers (replaying the stashed audio).
    /// Out of retries + an availability error (Siri/Dictation disabled, asset
    /// missing): surface an actionable message so the pill doesn't sit
    /// "listening" against a dead recognizer. Runs on main.
    private func recoverFromEarlyFailure(_ error: NSError) {
        guard !isTearingDown, !sawResult, finalCB == nil else { return }

        if usedOnDevice, !didServerRetry {
            didServerRetry = true
            retryViaServer()
            return
        }

        guard Self.isAvailabilityError(error) else { return }
        tearDown()
        onFatalError?("Apple speech recognition is unavailable. Turn on Dictation in System Settings → Keyboard, or switch engines in SolWhisper Settings → Dictation.")
    }

    /// Swaps the failed on-device request for a server-based one on the same
    /// running engine. Audio captured so far is replayed into the new request
    /// before it goes live, so the first words aren't lost.
    private func retryViaServer() {
        guard let recognizer, recognizer.isAvailable else {
            tearDown()
            onFatalError?("Apple speech recognition is unavailable. Turn on Dictation in System Settings → Keyboard, or switch engines in SolWhisper Settings → Dictation.")
            return
        }
        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎", label: "On-device speech failed — retrying via Apple servers",
                                ok: false)
        }
        usedOnDevice = false
        task?.cancel()

        // Replay + swap inside one critical section: the tap is blocked while
        // we backfill, so live buffers can't interleave ahead of the replayed
        // audio, and the tap never reads a half-swapped `request`. The stash is
        // tiny at this point (~10 buffers — the error fires ~200 ms in).
        let req = makeRequest(onDevice: false)
        stashLock.lock()
        stashedBuffers.forEach { req.append($0) }
        stashedBuffers = []
        request = req
        stashLock.unlock()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            self?.handleResult(result, error: error)
        }
    }

    private func makeRequest(onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(macOS 13, *) { req.addsPunctuation = true }
        if onDevice { req.requiresOnDeviceRecognition = true }
        return req
    }

    /// Copies tap buffers while a retry might still need them — the engine
    /// reuses the tap's buffer, so a reference alone would be overwritten.
    /// Called from the audio thread.
    private func stashForReplay(_ buf: AVAudioPCMBuffer) {
        stashLock.lock()
        defer { stashLock.unlock() }
        guard isStashing, stashedBuffers.count < Self.maxStashedBuffers,
              let copy = Self.copyBuffer(buf) else { return }
        stashedBuffers.append(copy)
    }

    private static func copyBuffer(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buf.frameLength > 0,
              let src = buf.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength),
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buf.frameLength
        let bytes = Int(buf.frameLength) * MemoryLayout<Float>.size
        for ch in 0..<Int(buf.format.channelCount) {
            memcpy(dst[ch], src[ch], bytes)
        }
        return copy
    }

    /// kAFAssistantErrorDomain: 1700/1701 = "Siri and Dictation are disabled",
    /// 1100/1101 = on-device asset unavailable. These mean recognition cannot
    /// work until the user changes a system setting — worth surfacing, unlike
    /// transient errors ("No speech detected", cancellations).
    static func isAvailabilityError(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain"
            && [1100, 1101, 1700, 1701].contains(error.code)
    }

    private func tearDown() {
        isTearingDown = true
        // `request` cleared under the lock too: an in-flight tap callback can
        // still be executing after removeTap returns.
        stashLock.lock()
        isStashing = false
        stashedBuffers = []
        request = nil
        stashLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Force the HAL audio unit to release the device so the macOS
        // mic-in-use indicator clears immediately. Without this, the
        // orange dot can linger after stop on some configurations.
        PreferredInputDevice.releaseInputNode(engine)
        task?.cancel()
        task     = nil
        // vDSP setup is a Core Foundation-managed handle — nilling the Swift
        // var is not enough; the backing buffers need an explicit destroy.
        // WhisperKitClient + MeetingAudioEngine.SpectrumComputer already do
        // this; missing it here leaked ~1 KB per session.
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
        fftSetup = nil
        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: AudioEngine.fftBinCount))
    }

    deinit {
        // Defensive: if start() succeeded and we somehow never reached
        // tearDown(), still free the vDSP handle.
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
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
