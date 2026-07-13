import AVFoundation
import XCTest
@testable import SolWhisper

/// Rotation-naming tests for `ChunkWriter`.
///
/// Regression guard for the chunk-index off-by-one: on every non-forced
/// rotation the writer must finalize `chunk-NNNN-mic.wav` with a *contiguous*
/// index and leave no `.tmp` behind. The pre-fix bug reopened each new chunk at
/// the old index, so `closeCurrentChunk` renamed a non-existent `index+1` file
/// and the real audio stayed stranded as `chunk-0000-mic.wav.tmp`,
/// `chunk-0001-mic.wav.tmp`, … — only `chunk-0000-mic.wav` was ever named, and
/// `CrashRecovery.chunkCount` reported "1 chunk" for any meeting.
final class ChunkWriterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunkwriter-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func format(_ sampleRate: Double = 48_000) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: false))
    }

    /// A non-silent mono buffer of exactly `frames` samples.
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buf.frameLength = frames
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<Int(frames) { ch[i] = Float(sin(Double(i) * 0.01) * 0.5) }
        }
        return buf
    }

    /// Feeding N full-chunk buffers must yield contiguously-named chunk files
    /// (0000, 0001, …) with no gaps and no leftover `.tmp`.
    func testRotationProducesContiguousChunksWithNoTmpLeftovers() async throws {
        let sampleRate: Double = 48_000
        let chunkSeconds: TimeInterval = 0.1                 // 4 800 frames / chunk
        let fmt = try format(sampleRate)
        let framesPerChunk = AVAudioFrameCount(sampleRate * chunkSeconds)

        let writer = try ChunkWriter(chunkDirectory: dir,
                                     chunkSeconds: chunkSeconds,
                                     micFormat: fmt,
                                     systemFormat: fmt)

        // Four full-size buffers → several forced rotations.
        for _ in 0..<4 {
            await writer.appendMic(try buffer(fmt, frames: framesPerChunk))
        }
        await writer.finalize()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)

        // No stranded temp files — the core regression signature.
        let tmp = files.filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(tmp.isEmpty, "Chunk rotation left stranded .tmp files: \(tmp.sorted())")

        // Mic chunk indices must be contiguous from 0 with no gaps.
        let indices = files
            .filter { $0.hasPrefix("chunk-") && $0.hasSuffix("-mic.wav") }
            .compactMap { name -> Int? in
                Int(name.dropFirst("chunk-".count).prefix(4))
            }
            .sorted()

        XCTAssertGreaterThanOrEqual(indices.count, 3,
            "Multiple rotations should produce multiple named chunks, got \(indices)")
        XCTAssertEqual(indices, Array(0...(indices.count - 1)),
            "Chunk indices must be contiguous from 0000 with no gaps, got \(indices)")
    }
}
