import AVFoundation
import Accelerate

/// Side-chain RMS ducking. When the mic side is loud (you're speaking), the
/// system side gets pulled down 8 dB so listeners can hear you cleanly when
/// the mixed audio is replayed.
///
/// Smooth attack 10 ms, release 200 ms. Tunables exposed on the struct so
/// Settings can override later (Sprint 7).
struct AudioMixer {
    var thresholdDB: Float = -40
    var duckDB: Float = -8
    var attackSeconds: Float = 0.010
    var releaseSeconds: Float = 0.200
    var sampleRate: Float = 48_000

    private var smoothedGain: Float = 1.0

    /// Mixes one block. `mic` and `system` must have the same frame length and
    /// channel count. Writes the mixed result into `out`.
    mutating func mix(mic: AVAudioPCMBuffer,
                      system: AVAudioPCMBuffer,
                      out: AVAudioPCMBuffer) {
        guard let micData = mic.floatChannelData,
              let sysData = system.floatChannelData,
              let outData = out.floatChannelData else { return }
        let frames = Int(mic.frameLength)
        let channels = Int(out.format.channelCount)

        // Compute mic RMS in dB
        var micSquare: Float = 0
        var n: vDSP_Length = vDSP_Length(frames)
        vDSP_measqv(micData[0], 1, &micSquare, n)
        let micRMS = sqrt(micSquare)
        let micDB = micRMS > 0 ? 20 * log10(micRMS) : -120

        // Target gain for the system channel.
        let targetGain: Float = (micDB > thresholdDB)
            ? pow(10, duckDB / 20)
            : 1.0

        // Per-buffer smoothing — exponential approach toward target.
        let blockTime = Float(frames) / sampleRate
        let coeff: Float
        if targetGain < smoothedGain {
            coeff = 1 - exp(-blockTime / attackSeconds)
        } else {
            coeff = 1 - exp(-blockTime / releaseSeconds)
        }
        smoothedGain += (targetGain - smoothedGain) * coeff
        let g = smoothedGain

        out.frameLength = mic.frameLength
        for ch in 0..<channels {
            let micCh = ch < Int(mic.format.channelCount) ? micData[ch] : micData[0]
            let sysCh = ch < Int(system.format.channelCount) ? sysData[ch] : sysData[0]
            for i in 0..<frames {
                outData[ch][i] = micCh[i] + sysCh[i] * g
            }
        }
    }

    /// Resets the smoothing envelope. Call on stream start so the first block
    /// doesn't fade in from 0 dB.
    mutating func reset() { smoothedGain = 1.0 }
}
