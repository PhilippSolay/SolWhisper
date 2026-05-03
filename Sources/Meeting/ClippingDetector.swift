import AVFoundation
import Accelerate

/// Per-buffer peak detection. If any sample in the buffer exceeds
/// `thresholdLinear`, the detector latches `isClipping = true` for
/// `latchSeconds`. The pill UI checks the flag on each render.
final class ClippingDetector {
    var thresholdDB: Float = -1
    var latchSeconds: TimeInterval = 1.0

    private(set) var isClipping = false
    private var latchUntil: Date = .distantPast

    private var thresholdLinear: Float {
        return pow(10, thresholdDB / 20)
    }

    /// Inspects a block; returns true if it triggered the latch.
    @discardableResult
    func observe(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return refresh() }
        let frames = vDSP_Length(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var anyAbove = false
        for ch in 0..<channels {
            var maxAmp: Float = 0
            vDSP_maxmgv(data[ch], 1, &maxAmp, frames)
            if maxAmp >= thresholdLinear { anyAbove = true; break }
        }
        if anyAbove {
            latchUntil = Date().addingTimeInterval(latchSeconds)
        }
        return refresh()
    }

    /// Refreshes the latch state without observing a new buffer.
    @discardableResult
    func refresh() -> Bool {
        isClipping = Date() < latchUntil
        return isClipping
    }
}
