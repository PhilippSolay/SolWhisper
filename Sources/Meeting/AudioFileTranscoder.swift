import Foundation
import AVFoundation
import CoreMedia

/// Transcodes an audio file to **mono AAC `.m4a`** via `AVAssetReader` →
/// `AVAssetWriter`.
///
/// Used for file→file work (the WAV→m4a archive compaction). The reader does
/// the stereo→mono downmix natively and hands the writer well-formed PCM sample
/// buffers, so this avoids the `AVAudioFile.read`/manual-`CMSampleBuffer`
/// fragility of the live-capture encoder (`AACMonoEncoder`). Source sample rate
/// is preserved; the bitrate is scaled down below 48 kHz so AAC never rejects
/// it ("encoding parameters are not supported").
enum AudioFileTranscoder {

    enum TranscodeError: Error {
        case noAudioTrack
        case cannotAddReaderOutput
        case cannotAddWriterInput
        case startReadFailed(String?)
        case startWriteFailed(String?)
        case readFailed(String?)
        case writeFailed(String?)
        case appendFailed(String?)
    }

    static func toMonoAAC(source: URL, dest: URL, bitRate: Int) async throws {
        try? FileManager.default.removeItem(at: dest)   // AVAssetWriter won't overwrite

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.noAudioTrack
        }

        // Preserve source sample rate; clamp bitrate proportionally below 48 kHz.
        var sampleRate = 48_000.0
        if let descs = try? await track.load(.formatDescriptions), let desc = descs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            sampleRate = asbd.mSampleRate
        }
        let effectiveBitRate = min(bitRate, Int((sampleRate / 48_000.0) * Double(bitRate)))

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,              // native downmix to mono
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(readerOutput) else { throw TranscodeError.cannotAddReaderOutput }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: dest, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: effectiveBitRate
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw TranscodeError.cannotAddWriterInput }
        writer.add(writerInput)

        guard reader.startReading() else { throw TranscodeError.startReadFailed(reader.error?.localizedDescription) }
        guard writer.startWriting() else { throw TranscodeError.startWriteFailed(writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)

        while let sample = readerOutput.copyNextSampleBuffer() {
            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed { throw TranscodeError.appendFailed(writer.error?.localizedDescription) }
                try await Task.sleep(nanoseconds: 500_000)   // 0.5 ms — offline backpressure
            }
            guard writerInput.append(sample) else {
                throw TranscodeError.appendFailed(writer.error?.localizedDescription)
            }
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard reader.status == .completed else { throw TranscodeError.readFailed(reader.error?.localizedDescription) }
        guard writer.status == .completed else { throw TranscodeError.writeFailed(writer.error?.localizedDescription) }
    }
}
