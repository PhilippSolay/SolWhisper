import AVFoundation
import Accelerate

class AudioEngine {
    var onAudioData:   ((Data) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?
    /// Delivers frequency magnitude bins (0…1 normalized), count = fftBinCount
    var onSpectrumUpdate: (([Float]) -> Void)?

    private let engine    = AVAudioEngine()
    private let mixer     = AVAudioMixerNode()
    private var converter: AVAudioConverter?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000, channels: 1, interleaved: true
    )!

    // Software processing state
    private var enhancementEnabled = false
    private var agcGain: Float = 1.0
    private let agcTarget:     Float = 0.08
    private let agcMaxGain:    Float = 12.0
    private let agcAttack:     Float = 0.05
    private let agcRelease:    Float = 0.005
    private let noiseGate:     Float = 0.004
    private let compThreshold: Float = 0.5
    private let compRatio:     Float = 4.0

    // FFT state — created in start(), read on the audio-tap thread, destroyed
    // only in deinit (never in stop) so an in-flight vDSP_DFT_Execute can't race
    // the destroy. Mirrors MeetingAudioEngine.SpectrumComputer.
    static let fftBinCount = 32
    private let fftSize = 1024
    private var fftSetup: vDSP_DFT_Setup?
    private var fftWindow = [Float]()
    private var fftAccum  = [Float](repeating: 0, count: 32)
    private var nativeSampleRate: Double = 48000

    // MARK: - Start

    func start() throws {
        let input       = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioEngineError.converterFailed
        }
        converter = conv
        enhancementEnabled = UserDefaults.standard.bool(forKey: "audioEnhancement")
        nativeSampleRate = inputFormat.sampleRate

        // Setup FFT
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        fftWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        engine.attach(mixer)
        engine.connect(input, to: mixer, format: inputFormat)

        mixer.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        try engine.start()
    }

    /// When true, audio buffers are silently dropped (no data/level/spectrum callbacks).
    var isPaused = false

    // MARK: - Stop

    func stop() {
        mixer.removeTap(onBus: 0)
        engine.stop()
        // Release the HAL audio unit's hold on the input device so macOS
        // clears the mic-in-use indicator immediately.
        PreferredInputDevice.releaseInputNode(engine)
        engine.detach(mixer)
        converter = nil
        agcGain   = 1.0
        // NOTE: the vDSP_DFT_Setup is deliberately NOT destroyed here. stop()
        // runs on the main thread, but computeSpectrum() calls vDSP_DFT_Execute
        // on the audio-tap thread and a tap callback can still be in flight
        // after removeTap returns — destroying here would free its buffers out
        // from under an in-flight execute. Destroyed in deinit instead.
        onLevelUpdate?(0)
        onSpectrumUpdate?([Float](repeating: 0, count: Self.fftBinCount))
    }

    deinit {
        stop()
        // Destroy the vDSP handle only now: by deinit the instance is
        // unreferenced (TranscriptionController allocates a fresh AudioEngine
        // per session), so no tap callback can still be executing an FFT. The
        // CF-managed handle needs an explicit destroy — nilling the Swift var
        // alone leaks ~1 KB/session. Mirrors MeetingAudioEngine.SpectrumComputer.
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
        fftSetup = nil
    }

    // MARK: - Buffer processing

    private func processBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        if isPaused { return }

        // Run FFT on the raw float buffer (native format) for UI
        if let floatData = inputBuffer.floatChannelData {
            computeSpectrum(floatData[0], frameCount: Int(inputBuffer.frameLength))
        }

        // Convert to 16kHz Int16 for STT
        let ratio       = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 2

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        var inputProvided = false
        var convError: NSError?

        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if inputProvided { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee  = .haveData
            inputProvided      = true
            return inputBuffer
        }

        guard status != .error,
              let channelData = outBuffer.int16ChannelData else { return }

        let n       = Int(outBuffer.frameLength)
        let enhance = enhancementEnabled

        // RMS
        var sum: Float = 0
        for i in 0..<n {
            let s = Float(channelData[0][i]) / Float(Int16.max)
            sum += s * s
        }
        let rms = n > 0 ? sqrt(sum / Float(n)) : 0

        // Noise gate
        if enhance && rms < noiseGate {
            onLevelUpdate?(0)
            onAudioData?(Data(count: n * 2))
            return
        }

        let outData: Data
        if enhance {
            // AGC
            if rms * agcGain < agcTarget {
                agcGain = min(agcGain * (1 + agcAttack), agcMaxGain)
            } else {
                agcGain = max(agcGain * (1 - agcRelease), 1.0)
            }

            var out = [Int16](repeating: 0, count: n)
            for i in 0..<n {
                var s = Float(channelData[0][i]) / Float(Int16.max) * agcGain
                let a = abs(s)
                if a > compThreshold {
                    let compressed = compThreshold + (a - compThreshold) / compRatio
                    s = s < 0 ? -compressed : compressed
                }
                out[i] = Int16(max(-1, min(1, s)) * Float(Int16.max))
            }
            outData = Data(bytes: out, count: n * 2)
        } else {
            outData = Data(bytes: channelData[0], count: n * 2)
        }

        let displayRMS = min((enhance ? rms * agcGain : rms) * 8, 1.0)
        onLevelUpdate?(displayRMS)
        onAudioData?(outData)
    }

    // MARK: - FFT Spectrum

    private func computeSpectrum(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard let setup = fftSetup else { return }
        let count = min(frameCount, fftSize)

        // Copy + window
        var windowed = [Float](repeating: 0, count: fftSize)
        for i in 0..<count {
            windowed[i] = samples[i] * fftWindow[i]
        }

        // Split complex for DFT
        var realIn  = [Float](repeating: 0, count: fftSize)
        var imagIn  = [Float](repeating: 0, count: fftSize)
        var realOut = [Float](repeating: 0, count: fftSize)
        var imagOut = [Float](repeating: 0, count: fftSize)

        realIn = windowed

        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        // Magnitude of first half (Nyquist)
        let halfN = fftSize / 2
        var magnitudes = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            magnitudes[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }

        // Normalize to 0–1
        var maxMag: Float = 0
        vDSP_maxv(magnitudes, 1, &maxMag, vDSP_Length(halfN))
        if maxMag > 0.001 {
            var scale = 1.0 / maxMag
            vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))
        }

        // Bin down to fftBinCount — only 300 Hz – 3000 Hz (speech range)
        let binCount  = Self.fftBinCount
        let hzPerBin  = Float(nativeSampleRate) / Float(fftSize)
        let loIdx     = max(0, Int(300.0 / hzPerBin))          // ~300 Hz
        let hiIdx     = min(halfN - 1, Int(3000.0 / hzPerBin)) // ~3000 Hz
        let rangeLen  = Float(max(1, hiIdx - loIdx))

        var bins = [Float](repeating: 0, count: binCount)
        for b in 0..<binCount {
            // Log-spaced mapping within the 300–3000 Hz window
            let fLo = Float(loIdx) + pow(Float(b)     / Float(binCount), 1.6) * rangeLen
            let fHi = Float(loIdx) + pow(Float(b + 1) / Float(binCount), 1.6) * rangeLen
            let lo  = max(loIdx, Int(fLo))
            let hi  = min(hiIdx, max(lo + 1, Int(fHi)))
            var sum: Float = 0
            for j in lo..<hi { sum += magnitudes[j] }
            bins[b] = sum / Float(max(1, hi - lo))
        }

        // Smooth with previous frame (temporal smoothing)
        let smooth: Float = 0.3
        for i in 0..<binCount {
            fftAccum[i] = fftAccum[i] * smooth + bins[i] * (1 - smooth)
        }

        onSpectrumUpdate?(fftAccum)
    }
}

enum AudioEngineError: Error {
    case converterFailed
}
