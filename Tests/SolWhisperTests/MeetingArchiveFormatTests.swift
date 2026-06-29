import AVFoundation
import XCTest
@testable import SolWhisper

/// Tests for the meeting archive encode path: `MeetingController.downmixToMono`
/// and `AACMonoEncoder`. These back the switch from float32 WAV to mono AAC
/// for the persisted `audio_mic/audio_system/audio` files.
final class MeetingArchiveFormatTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds a constant-valued float32 PCM buffer — one `values` entry per
    /// channel — so downmix math is exactly predictable.
    private func makeBuffer(channels: AVAudioChannelCount,
                            frames: AVAudioFrameCount,
                            values: [Float],
                            sampleRate: Double = 48_000) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: channels,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "test", code: 1)
        }
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for ch in 0..<Int(channels) {
            let p = data[ch]
            for i in 0..<Int(frames) { p[i] = values[ch] }
        }
        return buffer
    }

    // MARK: - Downmix

    func testDownmixAveragesStereoChannelsToMono() throws {
        // Arrange
        let stereo = try makeBuffer(channels: 2, frames: 256, values: [0.8, 0.2])

        // Act
        let mono = MeetingController.downmixToMono(stereo)

        // Assert
        XCTAssertEqual(mono?.format.channelCount, 1)
        XCTAssertEqual(mono?.frameLength, 256)
        let out = try XCTUnwrap(mono?.floatChannelData?[0])
        for i in 0..<256 {
            XCTAssertEqual(out[i], 0.5, accuracy: 1e-6, "L+R should average to 0.5")
        }
    }

    func testDownmixCancelsOppositePhaseToSilence() throws {
        // Arrange — perfectly out-of-phase L/R must average to zero.
        let stereo = try makeBuffer(channels: 2, frames: 64, values: [1.0, -1.0])

        // Act
        let mono = MeetingController.downmixToMono(stereo)

        // Assert
        let out = try XCTUnwrap(mono?.floatChannelData?[0])
        for i in 0..<64 { XCTAssertEqual(out[i], 0.0, accuracy: 1e-6) }
    }

    func testDownmixPassesMonoThroughUnchanged() throws {
        // Arrange
        let monoIn = try makeBuffer(channels: 1, frames: 100, values: [0.3])

        // Act
        let monoOut = MeetingController.downmixToMono(monoIn)

        // Assert
        XCTAssertEqual(monoOut?.format.channelCount, 1)
        XCTAssertEqual(monoOut?.frameLength, 100)
        let out = try XCTUnwrap(monoOut?.floatChannelData?[0])
        for i in 0..<100 { XCTAssertEqual(out[i], 0.3, accuracy: 1e-6) }
    }

    func testDownmixReturnsNilForEmptyBuffer() throws {
        // Arrange
        let empty = try makeBuffer(channels: 2, frames: 10, values: [0.5, 0.5])
        empty.frameLength = 0

        // Act / Assert
        XCTAssertNil(MeetingController.downmixToMono(empty))
    }

    // MARK: - End-to-end encode

    func testAacWriterProducesReadableMonoFileSmallerThanWav() async throws {
        // Arrange — 1 s of stereo sine (a realistic, compressible signal, unlike
        // a constant DC offset which AAC handles pathologically).
        let frames: AVAudioFrameCount = 48_000
        let sampleRate = 48_000.0
        let stereoFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                       sampleRate: sampleRate,
                                                       channels: 2,
                                                       interleaved: false))
        let stereo = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frames))
        stereo.frameLength = frames
        let left = stereo.floatChannelData![0]
        let right = stereo.floatChannelData![1]
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            left[i]  = Float(sin(twoPi * 440.0 * t) * 0.5)
            right[i] = Float(sin(twoPi * 660.0 * t) * 0.5)
        }
        let mono = try XCTUnwrap(MeetingController.downmixToMono(stereo))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aac-fixture-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        // Act — encode through AACMonoEncoder (AVAssetWriter path, honors bitrate).
        let encoder = try AACMonoEncoder(url: url, sampleRate: sampleRate, bitRate: 128_000)
        try encoder.append(mono)
        try await encoder.finish()

        // Assert — readable, mono, and far smaller than the float32 WAV would be.
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(reader.length, 0)

        // 1 s at 128 kbps CBR ≈ 16 KB audio + a few KB of MP4 container. Bound
        // it under 30 KB so a regression to the ~63 KB default-bitrate encode
        // (AVEncoderBitRateKey silently ignored) fails this test.
        let m4aSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(m4aSize, 4_000, "Suspiciously tiny — encode likely truncated")
        XCTAssertLessThan(m4aSize, 30_000,
                          "~1 s mono at 128 kbps should be ≈16–22 KB; larger means the bitrate cap was ignored")
    }
}
