import AVFoundation

class AudioEngine {
    var onAudioData: ((Data) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var levelTimer: Timer?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Use a compatible format for Deepgram: 16kHz mono PCM16
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        // Install tap on input — convert to 16kHz mono Int16 for Deepgram
        let converterNode = AVAudioMixerNode()
        engine.attach(converterNode)
        engine.connect(input, to: converterNode, format: format)

        converterNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self,
                  let channelData = buffer.int16ChannelData else { return }

            let frameLength = Int(buffer.frameLength)
            let data = Data(bytes: channelData[0], count: frameLength * 2)
            self.onAudioData?(data)

            // RMS level for waveform
            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = Float(channelData[0][i]) / Float(Int16.max)
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            self.onLevelUpdate?(min(rms * 10, 1.0))
        }

        try engine.start()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Level updates come from the tap
        }
    }

    func stop() {
        engine.stop()
        if let input = engine.inputNode as? AVAudioNode? {
            input?.removeTap(onBus: 0)
        }
        engine.inputNode.removeTap(onBus: 0)
        for node in engine.attachedNodes {
            engine.detach(node)
        }
        levelTimer?.invalidate()
        onLevelUpdate?(0)
    }
}
