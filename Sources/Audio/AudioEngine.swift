import AVFoundation

class AudioEngine {
    var onAudioData:   ((Data) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?

    private let engine    = AVAudioEngine()
    private let mixer     = AVAudioMixerNode()
    private var converter: AVAudioConverter?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000, channels: 1, interleaved: true
    )!

    // Software processing state
    private var agcGain: Float = 1.0
    private let agcTarget:     Float = 0.08
    private let agcMaxGain:    Float = 12.0
    private let agcAttack:     Float = 0.05
    private let agcRelease:    Float = 0.005
    private let noiseGate:     Float = 0.004
    private let compThreshold: Float = 0.5
    private let compRatio:     Float = 4.0

    // MARK: - Start

    func start() throws {
        let input       = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0) // native: e.g. 48kHz Float32

        // Converter: native mic format → 16kHz Int16 mono
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioEngineError.converterFailed
        }
        converter = conv

        engine.attach(mixer)
        engine.connect(input, to: mixer, format: inputFormat)

        // Tap in the NATIVE format — no format mismatch
        mixer.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        try engine.start()
    }

    // MARK: - Stop

    func stop() {
        mixer.removeTap(onBus: 0)
        engine.stop()
        engine.detach(mixer)   // only detach what we attached
        converter = nil
        agcGain   = 1.0
        onLevelUpdate?(0)
    }

    // MARK: - Buffer processing

    private func processBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        // Calculate output frame count proportional to sample rate ratio
        let ratio       = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 2

        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return }

        // Feed the input buffer once to the converter
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
        let enhance = UserDefaults.standard.bool(forKey: "audioEnhancement")

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
}

enum AudioEngineError: Error {
    case converterFailed
}
