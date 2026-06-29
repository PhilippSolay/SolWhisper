import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// Constant-bitrate **mono AAC** (`.m4a`) encoder built on `AVAssetWriter`.
///
/// `AVAudioFile(forWriting:settings:)` is deliberately **not** used for the
/// meeting archive: it silently ignores `AVEncoderBitRateKey` and encodes AAC
/// at a ~600 kbps default (verified — see `MeetingArchiveFormatTests`).
/// `AVAssetWriter`'s `outputSettings` honor the bitrate, which is what backs
/// the ~30× size reduction over the float32 WAV chunks.
///
/// Usage: feed mono float32 PCM buffers (e.g. `MeetingController.downmixToMono`
/// output) via `append(_:)`, then `await finish()`.
final class AACMonoEncoder {

    enum EncodeError: Error {
        case writerInit(String)
        case cannotAddInput
        case startFailed(String)
        case appendFailed(String)
        case sampleBufferCreate(OSStatus)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let sampleRate: Double
    private var nextSampleTime: Int64 = 0
    private var sessionStarted = false

    init(url: URL, sampleRate: Double, bitRate: Int) throws {
        self.sampleRate = sampleRate

        // AVAssetWriter refuses to overwrite — clear any stale file first.
        try? FileManager.default.removeItem(at: url)

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw EncodeError.writerInit(error.localizedDescription)
        }

        // AAC rejects bitrates too high for low sample rates ("encoding
        // parameters are not supported"). Scale the target down proportionally
        // below 48 kHz (e.g. 24 kHz → 64 kbps); 48 kHz+ keeps the full rate.
        let effectiveBitRate = min(bitRate, Int((sampleRate / 48_000.0) * Double(bitRate)))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: effectiveBitRate
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else { throw EncodeError.cannotAddInput }
        writer.add(input)
    }

    /// Appends one buffer of mono float32 PCM. Empty buffers are ignored.
    func append(_ pcm: AVAudioPCMBuffer) throws {
        guard pcm.frameLength > 0 else { return }
        try startIfNeeded()

        let pts = CMTime(value: nextSampleTime, timescale: CMTimeScale(sampleRate))
        guard let sample = Self.sampleBuffer(from: pcm, presentationTime: pts) else {
            throw EncodeError.sampleBufferCreate(-1)
        }

        // Offline encode: spin briefly if the encoder's queue is momentarily full.
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw EncodeError.appendFailed(writer.error?.localizedDescription ?? "writer failed")
            }
            Thread.sleep(forTimeInterval: 0.0005)
        }

        guard input.append(sample) else {
            throw EncodeError.appendFailed(writer.error?.localizedDescription ?? "append returned false")
        }
        nextSampleTime += Int64(pcm.frameLength)
    }

    /// Finalizes the container. Safe to call with zero appended buffers — it
    /// produces a valid (empty) `.m4a` so callers needn't special-case silence.
    func finish() async throws {
        try startIfNeeded()
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw EncodeError.appendFailed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    // MARK: - Private

    private func startIfNeeded() throws {
        guard !sessionStarted else { return }
        guard writer.startWriting() else {
            throw EncodeError.startFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    /// Wraps an `AVAudioPCMBuffer` in a `CMSampleBuffer` carrying the source PCM
    /// (the writer's `outputSettings` perform the PCM→AAC encode on append).
    private static func sampleBuffer(from pcm: AVAudioPCMBuffer,
                                     presentationTime: CMTime) -> CMSampleBuffer? {
        var asbd = pcm.format.streamDescription.pointee

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDesc = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: formatDesc,
                                   sampleCount: CMItemCount(pcm.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
                sb,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: pcm.audioBufferList) == noErr else { return nil }

        return sb
    }
}
