import Foundation
import AVFoundation
import Accelerate

/// Standalone dual-stream capture for meeting mode. **No reuse of the existing
/// `AudioEngine`** — that one is tuned for mode A (single-source dictation
/// hot path) and we don't want meeting-mode changes leaking into it.
///
/// Owns the mic (`AVAudioEngine`) and the system-audio (`SystemAudioCapture`)
/// streams. Surfaces:
///   - per-channel PCM buffers (for the chunk writer)
///   - per-channel level (for the pill UI)
///   - phase changes (for state machine)
///
/// Concurrency contract (per Sources/Meeting/ConcurrencyDesign.md):
///   - Tap callbacks run on a real-time audio thread; we do nothing slow there
///   - Level updates and PCM dispatch are funneled to MainActor via callbacks
///     that the controller wires through bounded streams to the disk writer
@MainActor
final class MeetingAudioEngine {

    enum Channel { case mic, system }

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused
        case stopping
        case stopped
        case failed(String)
    }

    // Set before start(). Closures run on MainActor (the engine dispatches
    // before invoking), so they're free to touch MainActor state directly.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevels: ((Float, Float) -> Void)?            // (mic, system) RMS in [0, 1]
    var onSpectrum: (([Float]) -> Void)?               // mic spectrum bins
    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }

    var isPaused: Bool {
        get { phase == .paused }
        set {
            if newValue && phase == .running { phase = .paused }
            else if !newValue && phase == .paused { phase = .running }
        }
    }

    /// Includes system audio if true. Settable before start; ignored mid-session.
    var capturesSystemAudio: Bool = true

    private let micEngine = AVAudioEngine()
    private let systemCapture = SystemAudioCapture()
    private var micFormat: AVAudioFormat?
    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0

    /// FFT helper that lives outside the @MainActor isolation domain so it
    /// can be touched safely from the audio tap thread. Created on `start()`,
    /// destroyed on `stop()`.
    private var spectrum: SpectrumComputer?

    func start() async throws {
        precondition(phase == .idle || phase == .stopped, "MeetingAudioEngine already running")
        phase = .starting

        try startMic()

        if capturesSystemAudio {
            systemCapture.onPCMBuffer = { [weak self] buffer, _ in
                guard let self else { return }
                Task { @MainActor in
                    guard !self.isPaused else { return }
                    self.lastSystemLevel = MeetingAudioEngine.rms(buffer)
                    self.onLevels?(self.lastMicLevel, self.lastSystemLevel)
                    self.onSystemBuffer?(buffer)
                }
            }
            systemCapture.onPhaseChange = { [weak self] sysPhase in
                if case .failed(let msg) = sysPhase {
                    self?.phase = .failed("System audio: \(msg)")
                }
            }
            do {
                try await systemCapture.start()
            } catch {
                phase = .failed("System audio start failed: \(error.localizedDescription)")
                throw error
            }
        }

        phase = .running
    }

    func stop() async {
        phase = .stopping
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        if capturesSystemAudio {
            await systemCapture.stop()
        }
        phase = .stopped
    }

    // MARK: - Private

    private func startMic() throws {
        // Apply the user's preferred input device BEFORE reading the format —
        // otherwise we lock in the system-default device's sample rate.
        PreferredInputDevice.applyToInputNode(micEngine)

        let input  = micEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        micFormat = format

        let comp = SpectrumComputer(sampleRate: format.sampleRate)
        spectrum = comp

        DebugLog.shared.log(icon: "🎙", label: "Meeting mic format",
                            value: "\(Int(format.sampleRate))Hz \(format.channelCount)ch")

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // The tap runs on the audio thread. Do the per-buffer DSP here
            // (RMS + FFT) and dispatch to MainActor for state mutations.
            let level = MeetingAudioEngine.rms(buffer)
            let bins = comp.compute(buffer)
            Task { @MainActor in
                guard !self.isPaused else { return }
                self.lastMicLevel = level
                self.onLevels?(self.lastMicLevel, self.lastSystemLevel)
                self.onSpectrum?(bins)
                self.onMicBuffer?(buffer)
            }
        }
        micEngine.prepare()
        try micEngine.start()
    }

    /// Computes the per-buffer RMS in [0, 1]. Run on whatever thread delivered
    /// the buffer — pure compute, no allocations.
    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)

        var totalSquare: Float = 0
        for ch in 0..<channels {
            for i in 0..<n {
                let s = data[ch][i]
                totalSquare += s * s
            }
        }
        let rms = sqrt(totalSquare / Float(n * max(1, channels)))
        return min(rms * 6, 1.0)
    }
}

// MARK: - SpectrumComputer

/// Computes log-spaced speech-band magnitude bins (300–3000 Hz) for the
/// pill waveform. Lives outside @MainActor isolation so the audio tap can
/// touch it on the realtime thread; @unchecked Sendable because all access
/// happens from a single thread (the tap callback) by construction.
final class SpectrumComputer: @unchecked Sendable {
    private let fftSize = 1024
    private let setup: vDSP_DFT_Setup?
    private var window: [Float]
    private var accum: [Float]
    private let nativeSampleRate: Double

    init(sampleRate: Double) {
        self.nativeSampleRate = sampleRate
        self.setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.accum = [Float](repeating: 0, count: AudioEngine.fftBinCount)
    }

    deinit {
        if let setup { vDSP_DFT_DestroySetup(setup) }
    }

    func compute(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let setup,
              let floatData = buffer.floatChannelData else { return accum }
        let frameCount = Int(buffer.frameLength)
        let count = min(frameCount, fftSize)

        var windowed = [Float](repeating: 0, count: fftSize)
        for i in 0..<count { windowed[i] = floatData[0][i] * window[i] }

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
            accum[i] = accum[i] * smooth + bins[i] * (1 - smooth)
        }
        return accum
    }
}
