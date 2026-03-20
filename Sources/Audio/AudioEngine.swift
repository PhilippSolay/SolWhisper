import AVFoundation

class AudioEngine {
    var onAudioData:   ((Data) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let mixer  = AVAudioMixerNode()

    // Software processing state
    private var agcGain: Float = 1.0

    // Tuning constants
    private let agcTarget:    Float = 0.08   // target RMS  (~-22 dBFS)
    private let agcMaxGain:   Float = 12.0   // max boost
    private let agcAttack:    Float = 0.05   // gain ramp-up  per buffer
    private let agcRelease:   Float = 0.005  // gain ramp-down per buffer
    private let noiseGate:    Float = 0.004  // gate threshold (~-48 dBFS)
    private let compThreshold: Float = 0.5   // soft-clip knee (~-6 dBFS)
    private let compRatio:     Float = 4.0   // compression ratio above knee

    // MARK: - Start

    func start() throws {
        let input       = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate:   16000,
            channels:     1,
            interleaved:  true
        )!

        engine.attach(mixer)
        engine.connect(input, to: mixer, format: inputFormat)

        mixer.installTap(onBus: 0, bufferSize: 4096, format: targetFormat) { [weak self] buffer, _ in
            guard let self,
                  let ch = buffer.int16ChannelData else { return }

            let n = Int(buffer.frameLength)
            let enhance = UserDefaults.standard.bool(forKey: "audioEnhancement")

            // --- Measure RMS ---
            var sum: Float = 0
            for i in 0..<n {
                let s = Float(ch[0][i]) / Float(Int16.max)
                sum += s * s
            }
            let rms = sqrt(sum / Float(n))

            // --- Noise gate ---
            if enhance && rms < self.noiseGate {
                self.onLevelUpdate?(0)
                self.onAudioData?(Data(count: n * 2)) // silence
                return
            }

            let outData: Data

            if enhance {
                // --- AGC: steer gain toward target RMS ---
                if rms * self.agcGain < self.agcTarget {
                    self.agcGain = min(self.agcGain * (1 + self.agcAttack), self.agcMaxGain)
                } else {
                    self.agcGain = max(self.agcGain * (1 - self.agcRelease), 1.0)
                }

                // --- Compress + apply gain ---
                var out = [Int16](repeating: 0, count: n)
                for i in 0..<n {
                    var s = Float(ch[0][i]) / Float(Int16.max) * self.agcGain

                    // Soft knee compressor above threshold
                    let abs_s = abs(s)
                    if abs_s > self.compThreshold {
                        let over  = abs_s - self.compThreshold
                        let compressed = self.compThreshold + over / self.compRatio
                        s = s < 0 ? -compressed : compressed
                    }

                    // Hard clip at ±1.0 then scale back to Int16
                    s = max(-1.0, min(1.0, s))
                    out[i] = Int16(s * Float(Int16.max))
                }
                outData = Data(bytes: out, count: n * 2)
            } else {
                outData = Data(bytes: ch[0], count: n * 2)
            }

            // Level for waveform (post-processing RMS)
            let displayRMS = enhance ? rms * self.agcGain : rms
            self.onLevelUpdate?(min(displayRMS * 8, 1.0))
            self.onAudioData?(outData)
        }

        try engine.start()
    }

    // MARK: - Stop

    func stop() {
        mixer.removeTap(onBus: 0)
        engine.stop()
        for node in engine.attachedNodes { engine.detach(node) }
        agcGain = 1.0
        onLevelUpdate?(0)
    }
}
