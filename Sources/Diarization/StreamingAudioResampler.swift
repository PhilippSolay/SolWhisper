import AVFoundation
import Foundation

/// Streaming audio resampler. Reads an audio file in fixed-size chunks,
/// runs each chunk through an `AVAudioConverter` configured for the target
/// format (16 kHz mono Float32 by default — what FluidAudio expects), and
/// reports granular progress as it goes.
///
/// Replaces the synchronous "load the whole 70-min file in one shot" path
/// that used to live inside `FluidAudioDiarizer`. That path had two bugs:
/// it gave no progress beyond the initial 5% jump, and on long files it
/// could hang for 15+ minutes inside a single uninterruptible call. The
/// chunked pipeline below reports progress per chunk and honours
/// `Task.checkCancellation()` so a stuck run can be cancelled cleanly.
enum StreamingAudioResampler {

    /// Default target rate matches FluidAudio's required input.
    static let defaultTargetSampleRate: Double = 16_000

    enum Error: Swift.Error, LocalizedError {
        case openFailed(URL, Swift.Error)
        case formatCreationFailed
        case converterInitFailed
        case readFailed(Swift.Error)
        case convertFailed(Swift.Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .openFailed(let url, let e):
                return "Couldn't open audio file at \(url.lastPathComponent): \(e.localizedDescription)"
            case .formatCreationFailed:
                return "Couldn't create target audio format (16 kHz mono Float)."
            case .converterInitFailed:
                return "Couldn't initialize the audio converter."
            case .readFailed(let e):
                return "Read failed while resampling: \(e.localizedDescription)"
            case .convertFailed(let e):
                return "Resample failed: \(e.localizedDescription)"
            case .cancelled:
                return "Resample cancelled."
            }
        }
    }

    /// Resamples `url` to mono Float32 at `targetSampleRate`. Reports progress
    /// 0.0...1.0 (linear in input frames consumed). Honours task cancellation
    /// — call `Task.cancel()` on the wrapping task to stop the run.
    ///
    /// `progress` is `@Sendable` — the resampler calls it inline rather than
    /// hopping to MainActor. Callers who need MainActor for SwiftUI bindings
    /// should wrap their callback in a `Task { @MainActor in … }`. This was
    /// the source of a real deadlock: while a modal `NSAlert.runModal` blocks
    /// the main thread (e.g. the launch-time permissions prompt), an internal
    /// `await MainActor.run` here meant every chunk's progress callback
    /// blocked the resample loop indefinitely, even though the actual decode
    /// work doesn't need MainActor at all.
    static func resampleToMonoFloat32(
        url: URL,
        targetSampleRate: Double = defaultTargetSampleRate,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [Float] {

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Error.openFailed(url, error)
        }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: targetSampleRate,
                                                channels: 1,
                                                interleaved: false) else {
            throw Error.formatCreationFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Error.converterInitFailed
        }

        // Read 8 seconds of input at a time. Big enough to amortize AVAudio
        // call overhead, small enough to surface progress on long files and
        // to keep peak memory bounded — peak input chunk for 8s of 48 kHz
        // stereo Float32 is ~3 MB, peak output chunk for 8s of 16 kHz mono
        // is ~512 KB.
        let readChunkSeconds: Double = 8
        let inputCapacity = AVAudioFrameCount(inputFormat.sampleRate * readChunkSeconds)

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                  frameCapacity: inputCapacity) else {
            throw Error.converterInitFailed
        }

        // Output capacity needs to account for the resampling ratio + a small
        // padding for converter latency.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: outputCapacity) else {
            throw Error.converterInitFailed
        }

        let totalFrames = file.length
        var framesRead: AVAudioFramePosition = 0
        var result: [Float] = []
        result.reserveCapacity(Int(Double(totalFrames) * ratio))

        while framesRead < totalFrames {
            try Task.checkCancellation()

            // Read up to inputCapacity frames into inputBuffer.
            do {
                try file.read(into: inputBuffer)
            } catch {
                throw Error.readFailed(error)
            }
            let consumedInputFrames = AVAudioFrameCount(inputBuffer.frameLength)
            if consumedInputFrames == 0 { break }
            framesRead += AVAudioFramePosition(consumedInputFrames)

            // Run the chunk through the converter. We feed once per call;
            // the converter pulls from the input buffer and writes to output.
            var inputConsumed = false
            var convertError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let err = convertError, status == .error {
                throw Error.convertFailed(err)
            }

            if let channel = outputBuffer.floatChannelData?[0] {
                let frames = Int(outputBuffer.frameLength)
                if frames > 0 {
                    let ptr = UnsafeBufferPointer(start: channel, count: frames)
                    result.append(contentsOf: ptr)
                }
            }

            // Reset the output buffer for the next iteration.
            outputBuffer.frameLength = 0

            let fraction = Double(framesRead) / Double(max(totalFrames, 1))
            progress(min(fraction, 0.999))
        }

        // Flush any tail samples the converter still holds.
        try Task.checkCancellation()
        var flushError: NSError?
        let flushStatus = converter.convert(to: outputBuffer, error: &flushError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        if let err = flushError, flushStatus == .error {
            throw Error.convertFailed(err)
        }
        if let channel = outputBuffer.floatChannelData?[0] {
            let frames = Int(outputBuffer.frameLength)
            if frames > 0 {
                let ptr = UnsafeBufferPointer(start: channel, count: frames)
                result.append(contentsOf: ptr)
            }
        }

        progress(1.0)
        return result
    }
}
