import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures system audio via ScreenCaptureKit — every other app's audio output
/// excluding our own (so we don't feed the mic-side back into recordings).
///
/// Audio-only configuration, 48 kHz stereo Float32. Output is delivered as
/// `AVAudioPCMBuffer` so callers can plumb it through the same audio path as
/// the mic input.
///
/// Concurrency contract (per Sources/Meeting/ConcurrencyDesign.md):
///   - SCStreamOutput callbacks run on a background queue we own (`outputQueue`)
///   - We never block in the callback — just convert + dispatch the buffer
///   - State changes (start / stop / errors) are surfaced to MainActor via
///     async callbacks
@MainActor
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case stopped
        case failed(String)
    }

    // Public callbacks — set before start()
    var onPCMBuffer: (@Sendable (AVAudioPCMBuffer, CMTime) -> Void)?
    var onPhaseChange: ((Phase) -> Void)?

    private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(
        label: "cloud.solay.SolWhisper.systemAudio",
        qos: .userInteractive
    )

    /// Sample rate of the stream output. Locked at 48 kHz to match the mic's
    /// preferred rate (avoids resample step in the time-aligner).
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    // MARK: - Permissions

    /// Returns true if Screen Recording permission has been granted. Triggers
    /// the system prompt on first call if not determined.
    static func ensurePermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Lifecycle

    func start() async throws {
        // `.failed(let msg)` is also a valid state to retry from — the
        // previous Phase.== with `.failed("")` only matched the empty-string
        // payload, so any real error in a prior start() left this
        // precondition tripping on the retry. Pattern-match instead.
        let canStart: Bool
        switch phase {
        case .idle, .stopped, .failed: canStart = true
        default:                       canStart = false
        }
        precondition(canStart, "SystemAudioCapture already running")
        phase = .starting

        let bundleID = Bundle.main.bundleIdentifier ?? "cloud.solay.SolWhisper"
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            phase = .failed("No display available for SCKit capture")
            throw NSError(domain: "SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        // Exclude our own process so the mic audio doesn't feed back into
        // the system-audio capture (issue #1 of dual-stream meetings).
        let selfApp = content.applications.first { $0.bundleIdentifier == bundleID }
        let excluded: [SCRunningApplication] = selfApp.map { [$0] } ?? []

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Int(Self.channelCount)
        // Video is required by SCStream even for audio-only — minimize it.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2
        config.queueDepth = 5
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio,
                                    sampleHandlerQueue: outputQueue)

        try await stream.startCapture()
        self.stream = stream
        phase = .running
        DebugLog.shared.log(icon: "🔉", label: "System audio capture started",
                            value: "\(Int(Self.sampleRate))Hz \(Self.channelCount)ch")
    }

    func stop() async {
        guard let stream else { phase = .stopped; return }
        phase = .stopping
        do {
            try await stream.stopCapture()
        } catch {
            DebugLog.shared.log(icon: "🔉", label: "System audio stop error",
                                value: "\(error)", ok: false)
        }
        self.stream = nil
        phase = .stopped
        DebugLog.shared.log(icon: "🔉", label: "System audio capture stopped")
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                             didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                             of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let buffer = Self.convertToPCMBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Snapshot the callback off-MainActor so we don't hop for every buffer.
        Task { [weak self] in
            await self?.dispatchBuffer(buffer, pts: pts)
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.phase = .failed(error.localizedDescription)
            DebugLog.shared.log(icon: "🔉", label: "System audio stream failed",
                                value: error.localizedDescription, ok: false)
        }
    }

    // MARK: - Private

    private func dispatchBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) {
        onPCMBuffer?(buffer, pts)
    }

    /// Converts a CMSampleBuffer (from SCKit) to an `AVAudioPCMBuffer` of
    /// Float32 non-interleaved at the source's native rate. Returns nil if
    /// the format is unexpected.
    nonisolated static func convertToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: false
        ) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer else { return nil }

        // SCKit delivers interleaved Float32 in a single contiguous buffer.
        // Deinterleave into the AVAudioPCMBuffer's per-channel layout.
        let channels = Int(asbd.mChannelsPerFrame)
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        let raw = UnsafeRawPointer(dataPointer)

        if isInterleaved {
            let floats = raw.bindMemory(to: Float.self,
                                         capacity: frameCount * channels)
            guard let channelData = pcm.floatChannelData else { return nil }
            for ch in 0..<channels {
                for i in 0..<frameCount {
                    channelData[ch][i] = floats[i * channels + ch]
                }
            }
        } else {
            // Already deinterleaved — copy each channel.
            let bytesPerChannel = totalLength / channels
            guard let channelData = pcm.floatChannelData else { return nil }
            for ch in 0..<channels {
                let src = (raw + ch * bytesPerChannel)
                          .bindMemory(to: Float.self, capacity: frameCount)
                for i in 0..<frameCount {
                    channelData[ch][i] = src[i]
                }
            }
        }

        return pcm
    }
}
