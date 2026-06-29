import AVFoundation
import XCTest
@testable import SolWhisper

/// Tests for `MeetingAudioCompaction` — the WAV→m4a re-encode + delete path.
/// This deletes the only copy of a recording, so the conversion + verify
/// behaviour is covered directly.
final class MeetingAudioCompactionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// Writes an N-second stereo float32 sine WAV at `name` under `tempDir`.
    @discardableResult
    private func writeStereoWav(_ name: String,
                               seconds: Double = 1.0,
                               sampleRate: Double = 48_000) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: sampleRate,
                                                 channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let twoPi = 2.0 * Double.pi
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            left[i]  = Float(sin(twoPi * 440.0 * t) * 0.5)
            right[i] = Float(sin(twoPi * 660.0 * t) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - convert

    func testConvertReencodesStereoWavToMonoM4aAndDeletesWav() async throws {
        // Arrange
        let wav = try writeStereoWav("audio.wav", seconds: 1.0)
        let m4a = tempDir.appendingPathComponent("audio.m4a")

        // Act
        let result = await MeetingAudioCompaction.convert(wavURL: wav, bitRate: 128_000)

        // Assert — converted, WAV gone, m4a present + mono + duration preserved.
        XCTAssertTrue(result.converted)
        XCTAssertGreaterThan(result.reclaimedBytes, 0, "AAC must be smaller than float32 WAV")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "WAV should be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path))

        let out = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(out.fileFormat.channelCount, 1, "Output must be mono")
        let outDuration = Double(out.length) / out.processingFormat.sampleRate
        XCTAssertEqual(outDuration, 1.0, accuracy: 0.1, "Duration must be preserved")
    }

    func testConvertReturnsFalseForMissingFile() async {
        // Arrange
        let missing = tempDir.appendingPathComponent("audio.wav")

        // Act
        let result = await MeetingAudioCompaction.convert(wavURL: missing, bitRate: 128_000)

        // Assert
        XCTAssertFalse(result.converted)
        XCTAssertEqual(result.reclaimedBytes, 0)
    }

    // MARK: - compact

    func testCompactConvertsAllThreeTracksAndLeavesOtherFiles() async throws {
        // Arrange — a meeting folder with the 3 recording tracks + an unrelated file.
        try writeStereoWav("audio.wav")
        try writeStereoWav("audio_mic.wav")
        try writeStereoWav("audio_system.wav")
        let notes = tempDir.appendingPathComponent("transcript.json")
        try Data("{}".utf8).write(to: notes)

        // Act
        let summary = await MeetingAudioCompaction.compact(folders: [tempDir], bitRate: 128_000)

        // Assert
        XCTAssertEqual(summary.converted, 3)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertGreaterThan(summary.reclaimedBytes, 0)

        let fm = FileManager.default
        for name in ["audio.wav", "audio_mic.wav", "audio_system.wav"] {
            XCTAssertFalse(fm.fileExists(atPath: tempDir.appendingPathComponent(name).path),
                           "\(name) should be gone")
        }
        for name in ["audio.m4a", "audio_mic.m4a", "audio_system.m4a"] {
            XCTAssertTrue(fm.fileExists(atPath: tempDir.appendingPathComponent(name).path),
                          "\(name) should exist")
        }
        XCTAssertTrue(fm.fileExists(atPath: notes.path), "Non-audio files must be untouched")
    }
}
