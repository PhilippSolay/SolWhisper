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

    // WhisperKit rescue: with Siri AND Dictation disabled, macOS refuses ALL
    // SFSpeechRecognizer work — a "server" retry task connects to no daemon,
    // never errors, and never produces results (verified via unified log:
    // kLSRErrorDomain 201 refusal, then silence). When that state is detected
    // we keep capturing into the stash and transcribe locally on stop.
    private var whisperRescue = false

    // Early-audio stash for the retry replay and the WhisperKit rescue.
    // Written from the audio tap thread, drained on main — guarded by
    // `stashLock`. Time-capped so a session that never errors doesn't
    // accumulate forever (cleared on first result).
    private let stashLock = NSLock()
    private var stashedBuffers: [AVAudioPCMBuffer] = []
    private var stashedFrames: AVAudioFramePosition = 0
    private var isStashing = true
    /// Rescue transcribes at most this much audio — dictations are short;
    /// 90 s of 44.1 kHz mono Float32 is ~16 MB of stash.
    private static let maxStashSeconds: Double = 90

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
        whisperRescue  = false
        stashLock.lock()
        stashedBuffers = []
        stashedFrames  = 0
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
        // Rescue mode: the recognizer is dead by system policy — skip
        // endAudio/watchdog entirely and transcribe the stash locally.
        if whisperRescue {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🍎", label: "Apple Speech stop",
                                    value: "WhisperKit rescue")
            }
            finishViaWhisperRescue(completion: completion)
            return
        }

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
            // Last-chance rescue: recognition went silent (no partials, no
            // error — e.g. a zombie server task) but the stash still holds
            // the session's audio. Hand it to WhisperKit instead of
            // returning empty.
            if t.isEmpty, self.canRescue() {
                Task { @MainActor in
                    DebugLog.shared.log(icon: "🍎",
                                        label: "Apple Speech silent — WhisperKit rescue",
                                        ok: false)
                }
                self.finishViaWhisperRescue(completion: cb)
                return
            }
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
            // Rescue mode: the recognizer was cancelled by system policy — a
            // late/spurious result must not clear the stash the rescue needs.
            guard !self.whisperRescue else { return }

            if !self.sawResult {
                // Recognition is alive — the retry stash is no longer needed.
                self.sawResult = true
                self.stashLock.lock()
                self.isStashing = false
                self.stashedBuffers = []
                self.stashedFrames = 0
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

    /// Recognizer died before producing any text. Recovery ladder:
    ///   1. "Siri and Dictation are disabled" (1700/1701) → WhisperKit rescue.
    ///      macOS refuses ALL SFSpeechRecognizer work in that state — a
    ///      server-mode retry task connects to no daemon and never errors, so
    ///      retrying would dictate into a black hole (verified via unified
    ///      log against localspeechrecognition's kLSRErrorDomain 201).
    ///   2. Forced on-device died some other way → retry once via Apple's
    ///      servers, replaying the stashed audio.
    ///   3. Out of retries + an availability error → WhisperKit rescue, or an
    ///      actionable message when no local model is downloaded, so the pill
    ///      doesn't sit "listening" against a dead recognizer. Runs on main.
    private func recoverFromEarlyFailure(_ error: NSError) {
        guard !isTearingDown, !sawResult, finalCB == nil, !whisperRescue else { return }

        if Self.isDictationDisabledError(error) {
            if !enterWhisperRescue() { failUnavailable() }
            return
        }

        if usedOnDevice, !didServerRetry {
            didServerRetry = true
            retryViaServer()
            return
        }

        guard Self.isAvailabilityError(error) else { return }
        if enterWhisperRescue() { return }
        failUnavailable()
    }

    private func failUnavailable() {
        tearDown()
        onFatalError?("Apple speech recognition is unavailable. Turn on Dictation in System Settings → Keyboard, switch engines in SolWhisper Settings → Dictation, or download a WhisperKit model in Settings → Models for offline dictation.")
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
        stashedFrames = 0
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

    // MARK: - WhisperKit rescue

    /// Arms rescue mode: the recognizer is dead by system policy, so stop
    /// feeding it, keep capturing into the stash, and transcribe locally on
    /// stop. Returns false when no WhisperKit model is on disk. Runs on main.
    private func enterWhisperRescue() -> Bool {
        guard Self.rescueModel(
            preferred: UserDefaults.standard.string(forKey: "whisperKitModel"),
            isDownloaded: { WhisperKitClient.isModelDownloaded($0) }
        ) != nil else { return false }

        whisperRescue = true
        task?.cancel()
        task = nil
        stashLock.lock()
        request = nil          // tap keeps stashing; nothing left to feed
        stashLock.unlock()
        Task { @MainActor in
            DebugLog.shared.log(icon: "🍎",
                                label: "Apple dictation disabled — WhisperKit rescue armed",
                                ok: false)
        }
        onTranscript?("(Apple dictation off — transcribing on stop…)", false)
        return true
    }

    private func canRescue() -> Bool {
        stashLock.lock()
        let hasAudio = !stashedBuffers.isEmpty
        stashLock.unlock()
        return hasAudio && Self.rescueModel(
            preferred: UserDefaults.standard.string(forKey: "whisperKitModel"),
            isDownloaded: { WhisperKitClient.isModelDownloaded($0) }
        ) != nil
    }

    /// Writes the stashed session audio to a temp file, transcribes it with
    /// the local WhisperKit model, and completes with the text. Tears the
    /// engine down first so the mic indicator clears the moment the user
    /// stops. Runs on main.
    private func finishViaWhisperRescue(completion: @escaping (String?) -> Void) {
        // Snapshot the audio before tearDown wipes the stash.
        stashLock.lock()
        let buffers = stashedBuffers
        stashedBuffers = []
        isStashing = false
        stashLock.unlock()

        let model = Self.rescueModel(
            preferred: UserDefaults.standard.string(forKey: "whisperKitModel"),
            isDownloaded: { WhisperKitClient.isModelDownloaded($0) }
        )
        let elapsed = watch?.elapsed
        tearDown()

        guard let model, !buffers.isEmpty else {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🍎", label: "WhisperKit rescue unavailable",
                                    value: buffers.isEmpty ? "no audio captured" : "no model downloaded",
                                    ok: false)
            }
            completion(nil)
            return
        }

        onTranscript?("(transcribing offline via \(WhisperKitClient.displayName(for: model))…)", false)

        // First-finish-wins between the transcription and a safety timeout —
        // a hung model load must not leave the pill waiting forever.
        let lock = NSLock()
        var didFinish = false
        var safety: DispatchWorkItem?
        let finish: (String?) -> Void = { text in
            lock.lock()
            let first = !didFinish
            didFinish = true
            lock.unlock()
            guard first else { return }
            safety?.cancel()
            completion(text)
        }

        let safetyWork = DispatchWorkItem {
            Task { @MainActor in
                DebugLog.shared.log(icon: "⏱", label: "WhisperKit rescue timeout",
                                    value: "no result after 60s — bailing", ok: false)
            }
            finish(nil)
        }
        safety = safetyWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: safetyWork)

        Task { @MainActor in
            do {
                let url = Self.makeRescueURL()
                try Self.writeBuffers(buffers, to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                DebugLog.shared.log(icon: "🍎", label: "WhisperKit rescue transcribing",
                                    value: model)
                let segments = try await WhisperKitClient.fileTranscribe(
                    audioPath: url, model: model, progress: nil
                )
                let text = segments.map { $0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DebugLog.shared.log(icon: "🍎", label: "WhisperKit rescue done",
                                    value: text.isEmpty ? "(empty)" : "\"\(String(text.prefix(80)))\"",
                                    ms: elapsed)
                finish(text.isEmpty ? nil : text)
            } catch {
                DebugLog.shared.log(icon: "🍎", label: "WhisperKit rescue failed",
                                    value: "\(error)", ok: false)
                finish(nil)
            }
        }
    }

    /// Rescue model choice: the dictation WhisperKit selection when it's on
    /// disk, else the default model, else any downloaded model (smallest
    /// first — supportedModels is ordered by size), else none.
    static func rescueModel(preferred: String?,
                            isDownloaded: (String) -> Bool) -> String? {
        if let preferred, isDownloaded(preferred) { return preferred }
        if isDownloaded(WhisperKitClient.defaultModel) { return WhisperKitClient.defaultModel }
        return WhisperKitClient.supportedModels.first(where: isDownloaded)
    }

    /// Writes PCM buffers sequentially to a CAF file in their native format.
    static func writeBuffers(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        guard let first = buffers.first else {
            throw AppleSpeechError.unavailable
        }
        let format = first.format
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        for buf in buffers {
            try file.write(from: buf)
        }
    }

    private static func makeRescueURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("solwhisper-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("apple-rescue-\(UUID().uuidString).caf")
    }

    /// Copies tap buffers while a retry or rescue might still need them — the
    /// engine reuses the tap's buffer, so a reference alone would be
    /// overwritten. Called from the audio thread.
    private func stashForReplay(_ buf: AVAudioPCMBuffer) {
        stashLock.lock()
        defer { stashLock.unlock() }
        let maxFrames = AVAudioFramePosition(Self.maxStashSeconds * buf.format.sampleRate)
        guard isStashing, stashedFrames < maxFrames,
              let copy = Self.copyBuffer(buf) else { return }
        stashedBuffers.append(copy)
        stashedFrames += AVAudioFramePosition(copy.frameLength)
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

    /// The subset of availability errors where macOS refuses ALL
    /// SFSpeechRecognizer work, on-device AND server: with Siri + Dictation
    /// both off, even a server-mode task connects to no daemon and just goes
    /// silent. A retry can't help — only the WhisperKit rescue can.
    /// 1100/1101 (asset missing) are excluded: the server path works there.
    static func isDictationDisabledError(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain"
            && [1700, 1701].contains(error.code)
    }

    private func tearDown() {
        isTearingDown = true
        // `request` cleared under the lock too: an in-flight tap callback can
        // still be executing after removeTap returns.
        stashLock.lock()
        isStashing = false
        stashedBuffers = []
        stashedFrames = 0
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
        // NOTE: the vDSP_DFT_Setup is deliberately NOT destroyed here. tearDown
        // runs on the main thread, but emitSpectrum() calls vDSP_DFT_Execute on
        // the audio-tap thread and a tap callback can still be in flight after
        // removeTap returns — destroying here would free its buffers out from
        // under an in-flight execute. Destroyed in deinit instead.
        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: AudioEngine.fftBinCount))
    }

    deinit {
        // Sole destroy site for the vDSP handle. By deinit the instance is
        // unreferenced (a fresh AppleSpeechClient is allocated per session), so
        // no audio-tap callback can still be running emitSpectrum — the tap
        // strongifies `self`, which would keep deinit from running mid-execute.
        // Mirrors MeetingAudioEngine.SpectrumComputer.
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
