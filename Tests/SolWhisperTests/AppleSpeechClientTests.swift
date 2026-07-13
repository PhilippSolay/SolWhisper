import XCTest
import AVFoundation
@testable import SolWhisper

final class AppleSpeechClientTests: XCTestCase {

    // MARK: - Availability-error classification

    private func assistantError(_ code: Int) -> NSError {
        NSError(domain: "kAFAssistantErrorDomain", code: code)
    }

    func testSiriAndDictationDisabledIsAvailabilityError() {
        // kAFAssistantErrorDomain 1700 — "Siri and Dictation are disabled".
        // The exact failure that ships an actionable message to the user.
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1700)))
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1701)))
    }

    func testMissingOnDeviceAssetIsAvailabilityError() {
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1100)))
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1101)))
    }

    func testTransientRecognizerErrorsAreNotAvailabilityErrors() {
        // "No speech detected" / retry-class errors must NOT tear down the
        // session with a settings banner.
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(assistantError(203)))
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(assistantError(216)))
    }

    func testCancellationFromOtherDomainIsNotAvailabilityError() {
        // Our own retry path cancels the failed on-device task; the resulting
        // "Recognition request was canceled" must never be treated as fatal.
        let cancel = NSError(domain: "kLSRErrorDomain", code: 301)
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(cancel))
        // Same code in an unrelated domain.
        let unrelated = NSError(domain: NSURLErrorDomain, code: 1700)
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(unrelated))
    }

    // MARK: - WhisperKit rescue (Siri + Dictation disabled)

    func testDictationDisabledClassification() {
        // 1700/1701 mean macOS refuses ALL SFSpeechRecognizer work — even a
        // "server" retry task connects to nothing (verified via unified log).
        XCTAssertTrue(AppleSpeechClient.isDictationDisabledError(assistantError(1700)))
        XCTAssertTrue(AppleSpeechClient.isDictationDisabledError(assistantError(1701)))
        // Asset-missing errors leave the server path viable — NOT this class.
        XCTAssertFalse(AppleSpeechClient.isDictationDisabledError(assistantError(1100)))
        XCTAssertFalse(AppleSpeechClient.isDictationDisabledError(assistantError(1101)))
        XCTAssertFalse(AppleSpeechClient.isDictationDisabledError(
            NSError(domain: NSURLErrorDomain, code: 1700)))
    }

    func testRescueModelPrefersDictationSelectionThenDefault() {
        XCTAssertEqual(
            AppleSpeechClient.rescueModel(preferred: "small.en", isDownloaded: { _ in true }),
            "small.en")
        // Preferred model not on disk → fall back to the default model.
        XCTAssertEqual(
            AppleSpeechClient.rescueModel(preferred: "small.en",
                                          isDownloaded: { $0 == WhisperKitClient.defaultModel }),
            WhisperKitClient.defaultModel)
        // Nothing downloaded → no rescue possible.
        XCTAssertNil(
            AppleSpeechClient.rescueModel(preferred: "small.en", isDownloaded: { _ in false }))
        // No preference stored → default model when available.
        XCTAssertEqual(
            AppleSpeechClient.rescueModel(preferred: nil,
                                          isDownloaded: { $0 == WhisperKitClient.defaultModel }),
            WhisperKitClient.defaultModel)
        // Neither preferred nor default on disk, but SOME model is → use it.
        // (Real case: meetings downloaded small.en; dictation pref base.en absent.)
        XCTAssertEqual(
            AppleSpeechClient.rescueModel(preferred: "base.en",
                                          isDownloaded: { $0 == "small.en" }),
            "small.en")
    }

    func testWriteBuffersRoundTrip() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                 sampleRate: 44_100,
                                                 channels: 1,
                                                 interleaved: false))
        let frames: AVAudioFrameCount = 4410
        let buffers: [AVAudioPCMBuffer] = try (0..<5).map { i in
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buf.frameLength = frames
            for f in 0..<Int(frames) {
                buf.floatChannelData![0][f] = sinf(Float(f + i * Int(frames)) * 0.05)
            }
            return buf
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescue-roundtrip-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        try AppleSpeechClient.writeBuffers(buffers, to: url)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, AVAudioFramePosition(5 * frames),
                       "Every stashed frame must land in the rescue file")
    }

    func testWriteBuffersRejectsEmptyStash() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescue-empty-\(UUID().uuidString).caf")
        XCTAssertThrowsError(try AppleSpeechClient.writeBuffers([], to: url))
    }
}
