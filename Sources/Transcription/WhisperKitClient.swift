import Foundation
import AVFoundation
import Accelerate
import os
import WhisperKit

enum WhisperKitClientError: Error {
    case modelNotLoaded(String)
    case audioFileWriteFailed(String)
    case audioFileMissing(URL)
    case noResults
}

/// Live mode-A recording session that captures mic to a temp file and runs
/// WhisperKit non-streaming transcription on stop. Mirrors the shape of
/// `AppleSpeechClient` (start / stopAndFinalize / cancel) so
/// `TranscriptionController` can use it as a drop-in third backend.
///
/// The static `fileTranscribe`, `download`, and `isModelDownloaded` helpers
/// are reused by Sprint 2's file-import path — keep them pure.
///
/// v0.4 ships non-streaming only; live partials are deferred to v0.5
/// (see plans/MEETING-FEATURES-PLAN.md §12.1). The pill bubble shows a
/// "transcribing on stop" placeholder while recording.
@MainActor
final class WhisperKitClient {

    var onTranscript:    ((String, Bool) -> Void)?
    var onLevelUpdate:   ((Float) -> Void)?
    var onSpectrumUpdate: (([Float]) -> Void)?

    private let model: String
    private let engine = AVAudioEngine()
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var nativeSampleRate: Double = 48_000
    private var watch: Stopwatch?
    private var transcribeTask: Task<Void, Never>?
    /// When true, the audio tap drops buffers instead of writing them to the
    /// rolling WAV file. WhisperKit transcribes whatever was captured on stop —
    /// pause means "don't capture this section."
    var isPaused = false

    // FFT (mirrors AppleSpeechClient — same speech band, same smoothing)
    private let fftSize = 1024
    private var fftSetup: vDSP_DFT_Setup?
    private var fftWindow = [Float]()
    private var fftAccum  = [Float](repeating: 0, count: AudioEngine.fftBinCount)

    init(model: String) {
        self.model = model
    }

    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
    }

    // MARK: - Live mode-A pattern

    func start() throws {
        watch = Stopwatch()

        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftAccum = [Float](repeating: 0, count: AudioEngine.fftBinCount)

        // Honor the user's preferred mic device.
        PreferredInputDevice.applyToInputNode(engine)
        let input  = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        nativeSampleRate = format.sampleRate

        let url = WhisperKitClient.makeTempRecordingURL()
        recordingURL = url
        do {
            recordingFile = try AVAudioFile(forWriting: url,
                                            settings: format.settings,
                                            commonFormat: format.commonFormat,
                                            interleaved: format.isInterleaved)
        } catch {
            throw WhisperKitClientError.audioFileWriteFailed("\(error)")
        }

        DebugLog.shared.log(icon: "🟣", label: "WhisperKit recording start",
                            value: "\(Int(format.sampleRate))Hz \(format.channelCount)ch · model=\(model)")

        // Tell user this backend transcribes on stop (no live partials in v0.4)
        onTranscript?("(transcribing on stop…)", false)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self else { return }
            // Pause: drop buffers so the recording doesn't capture them.
            if self.isPaused { return }
            try? self.recordingFile?.write(from: buf)
            self.emitLevel(buf)
            self.emitSpectrum(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stopAndFinalize(completion: @escaping (String?) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Release the HAL audio unit's hold on the device so macOS clears
        // the mic-in-use indicator the moment the user stops.
        PreferredInputDevice.releaseInputNode(engine)
        recordingFile = nil

        guard let url = recordingURL else {
            completion(nil)
            return
        }
        recordingURL = nil

        let elapsed = watch?.elapsed
        let model = self.model
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        DebugLog.shared.log(icon: "🟣", label: "WhisperKit recording stopped",
                            value: "\(fileSize / 1024) KB at \(url.lastPathComponent)")

        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: AudioEngine.fftBinCount))
        onTranscript?("(loading \(model)…)", false)

        let safetyTimeoutSeconds: Double = 90
        var safetyTask: Task<Void, Never>?
        var didFinish = false
        let lock = NSLock()
        let finish: (String?) -> Void = { result in
            lock.lock()
            let firstFinish = !didFinish
            didFinish = true
            lock.unlock()
            guard firstFinish else { return }
            safetyTask?.cancel()
            try? FileManager.default.removeItem(at: url)
            completion(result)
        }

        transcribeTask = Task { @MainActor in
            DebugLog.shared.log(icon: "🟣", label: "WhisperKit loading model", value: model)
            do {
                let segments = try await WhisperKitClient.fileTranscribe(
                    audioPath: url, model: model, progress: nil
                )
                let text = segments.map { $0.text }.joined(separator: " ")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DebugLog.shared.log(icon: "🟣", label: "WhisperKit done",
                                    value: text.isEmpty ? "(empty)" : "\"\(String(text.prefix(80)))\"",
                                    ms: elapsed)
                finish(text.isEmpty ? nil : text)
            } catch {
                DebugLog.shared.log(icon: "🟣", label: "WhisperKit error",
                                    value: "\(error)", ok: false)
                finish(nil)
            }
        }

        safetyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(safetyTimeoutSeconds * 1_000_000_000))
            if !Task.isCancelled {
                DebugLog.shared.log(icon: "⏱", label: "WhisperKit timeout",
                                    value: "no result after \(Int(safetyTimeoutSeconds))s — bailing",
                                    ok: false)
                self.transcribeTask?.cancel()
                finish(nil)
            }
        }
    }

    func cancel() {
        transcribeTask?.cancel()
        transcribeTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        PreferredInputDevice.releaseInputNode(engine)
        recordingFile = nil
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: AudioEngine.fftBinCount))
    }

    // MARK: - Static API (reused by Sprint 2 file import)

    /// Curated v0.4 model list. WhisperKit also exposes
    /// `WhisperKit.fetchAvailableModels()` for the full remote list — these are
    /// the ones we test against and surface in the settings picker.
    nonisolated static let supportedModels: [String] = [
        "tiny.en",
        "base.en",
        "small.en",
        "large-v3-turbo"
    ]

    nonisolated static let defaultModel = "base.en"

    /// Custom on-disk model location. Keeps WhisperKit's downloads out of
    /// `~/Documents/huggingface` (its default).
    static var modelsDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Heuristic check: WhisperKit downloads land in
    /// `<modelsDirectory>/<repo>/<openai_*-<model>-...>/`. We just walk and
    /// look for any directory whose name contains the model variant.
    static func isModelDownloaded(_ model: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelsDirectory.path),
              let enumerator = fm.enumerator(at: modelsDirectory,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && url.lastPathComponent.contains(model) {
                return true
            }
        }
        return false
    }

    /// Explicit pre-download with progress, for "Download model now" affordances.
    /// `WhisperKitConfig.download = true` (used by `fileTranscribe`) does the same
    /// silently, but without progress callbacks.
    static func downloadModel(
        _ model: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        return try await WhisperKit.download(
            variant: model,
            downloadBase: modelsDirectory,
            progressCallback: { p in
                progress?(p.fractionCompleted)
            }
        )
    }

    /// Pure file-based transcription. Used by mode-A on stop and by Sprint 2's
    /// file import. Returns our in-app `TranscriptSegment` model (start/end/text).
    ///
    /// Cancellation: `Task.cancel()` propagates into WhisperKit via
    /// `Task.checkCancellation()` (verified upstream in `TranscribeTask.run`).
    static func fileTranscribe(
        audioPath: URL,
        model: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        // Fail fast before paying the model load / download cost.
        guard FileManager.default.fileExists(atPath: audioPath.path) else {
            throw WhisperKitClientError.audioFileMissing(audioPath)
        }
        try Task.checkCancellation()

        let loadStart = Date()
        let whisper = try await sharedInstance(for: model)
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        Task { @MainActor in
            DebugLog.shared.log(icon: "🟣", label: "WhisperKit model loaded",
                                value: "\(model) in \(loadMs)ms")
        }
        try Task.checkCancellation()

        // KVO `progress.fractionCompleted` from a single observer (issue #331).
        var observer: NSKeyValueObservation?
        if let progress {
            observer = whisper.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                progress(p.fractionCompleted)
            }
        }
        defer { observer?.invalidate() }

        let txStart = Date()
        Task { @MainActor in
            DebugLog.shared.log(icon: "🟣", label: "WhisperKit transcribe start",
                                value: audioPath.lastPathComponent)
        }
        // VAD chunking splits long-form audio on silence and decodes chunks
        // concurrently (concurrentWorkerCount defaults to 16 on macOS in
        // WhisperKit's DecodingOptions init). Without this, long recordings
        // run as a single sequential 30s-window decode and a 70-min file
        // takes 15+ minutes per channel on M-series. With VAD chunking the
        // same file is typically 3-5x faster with the same or better accuracy.
        let options = DecodingOptions(chunkingStrategy: .vad)
        let results = try await whisper.transcribe(
            audioPath: audioPath.path,
            decodeOptions: options,
            callback: nil
        )
        let txMs = Int(Date().timeIntervalSince(txStart) * 1000)
        Task { @MainActor in
            DebugLog.shared.log(icon: "🟣", label: "WhisperKit transcribe finished",
                                value: "\(results.count) result(s) in \(txMs)ms")
        }

        guard let first = results.first else {
            throw WhisperKitClientError.noResults
        }

        return first.segments.map { wk in
            TranscriptSegment(
                start: TimeInterval(wk.start),
                end: TimeInterval(wk.end),
                text: stripSpecialTokens(wk.text),
                confidence: nil,
                speaker: .unknown
            )
        }
    }

    /// WhisperKit's per-segment `text` includes the model's special prefix tokens
    /// (`<|startoftranscript|>`, `<|0.00|>` timestamp markers, `<|en|>`, etc.). The
    /// parent `TranscriptionResult.text` already strips these for the joined output,
    /// but per-segment text leaks them. Clean before surfacing to the rest of the app.
    /// Defensive `try?` — pattern is hardcoded and known-good, but a regex
    /// engine quirk shouldn't crash the whole app.
    private static let specialTokenRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<\\|[^|]*\\|>", options: []
    )

    static func stripSpecialTokens(_ raw: String) -> String {
        guard let specialTokenRegex else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        let cleaned = specialTokenRegex.stringByReplacingMatches(
            in: raw, options: [], range: range, withTemplate: ""
        )
        // Collapse the double-spaces left where tokens used to be.
        let collapsed = cleaned.replacingOccurrences(
            of: " +", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared instance cache

    /// Async-safe cache for the lazily-loaded WhisperKit instance. `OSAllocatedUnfairLock`
    /// is the macOS 13+ replacement for NSLock that's safe to use across `await`s.
    private struct InstanceCache: Sendable {
        var instance: WhisperKit?
        var model: String?
    }
    private static let instanceCache = OSAllocatedUnfairLock(initialState: InstanceCache())

    /// Lazy-loaded WhisperKit per model. Reused across calls — recreate via
    /// `resetCache()` after long sessions (issue #393 CoreML resource leak).
    /// For v0.4 mode A (one-shot per recording) this single-instance cache
    /// is well within the leak's safe window.
    private static func sharedInstance(for model: String) async throws -> WhisperKit {
        let cached = instanceCache.withLock { state -> WhisperKit? in
            state.model == model ? state.instance : nil
        }
        if let cached { return cached }

        let config = WhisperKitConfig(
            model: model,
            downloadBase: modelsDirectory,
            verbose: false,
            logLevel: .info,
            load: true,
            download: true
        )
        let instance = try await WhisperKit(config)

        instanceCache.withLock { state in
            state.instance = instance
            state.model = model
        }

        return instance
    }

    /// Drops the cached `WhisperKit` instance. Call after model-switch in settings
    /// or after long sessions to mitigate upstream issue #393.
    static func resetCache() {
        instanceCache.withLock { state in
            state.instance = nil
            state.model = nil
        }
    }

    // MARK: - Private

    private static func makeTempRecordingURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("solwhisper-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rec-\(UUID().uuidString).caf")
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
