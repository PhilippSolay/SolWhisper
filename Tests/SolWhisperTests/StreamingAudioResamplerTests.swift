import AVFoundation
import XCTest
@testable import SolWhisper

/// Tests for `StreamingAudioResampler.resampleToMonoFloat32`.
///
/// Generates a tiny in-memory WAV fixture (1 s, 48 kHz, stereo, Float32
/// PCM) at a temp URL so we exercise the real `AVAudioConverter` path
/// without shipping audio binaries in the repo.
final class StreamingAudioResamplerTests: XCTestCase {

    // MARK: - Fixture

    /// Writes a 1-second 48 kHz stereo Float32 sine-wave WAV to a temp URL.
    /// Each channel gets a different frequency so the file isn't silence
    /// (defensive — silent input has tripped resampler bugs in other libs).
    private func writeStereoSineFixture(
        durationSeconds: Double = 1.0,
        sampleRate: Double = 48_000
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "resampler-fixture-\(UUID().uuidString).wav"
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            XCTFail("Couldn't build source format")
            throw NSError(domain: "test", code: 1)
        }

        let file = try AVAudioFile(forWriting: url,
                                    settings: format.settings,
                                    commonFormat: .pcmFormatFloat32,
                                    interleaved: false)

        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: frameCount) else {
            XCTFail("Couldn't allocate fixture buffer")
            throw NSError(domain: "test", code: 2)
        }
        buffer.frameLength = frameCount

        let leftFreq: Double  = 440.0  // A4
        let rightFreq: Double = 660.0  // E5
        let twoPi = 2.0 * Double.pi

        if let left = buffer.floatChannelData?[0],
           let right = buffer.floatChannelData?[1] {
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                left[i]  = Float(sin(twoPi * leftFreq  * t) * 0.5)
                right[i] = Float(sin(twoPi * rightFreq * t) * 0.5)
            }
        }

        try file.write(from: buffer)
        return url
    }

    // MARK: - Happy path

    func testResamplesStereo48kTo16kMono() async throws {
        let url = try writeStereoSineFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try await StreamingAudioResampler.resampleToMonoFloat32(
            url: url,
            targetSampleRate: 16_000,
            progress: { _ in }
        )

        // 1 s @ 16 kHz → ~16000 samples. AVAudioConverter has small latency
        // and may emit a slightly different count; ±200 is a comfortable
        // tolerance that still catches gross regressions (off-by-2x etc).
        XCTAssertGreaterThan(samples.count, 15_500,
                             "Expected ~16k mono samples; got \(samples.count)")
        XCTAssertLessThan(samples.count, 16_500,
                          "Expected ~16k mono samples; got \(samples.count)")

        // Sanity: not all zeros (mixing two non-silent channels shouldn't
        // null out, and a resampling bug producing silence has happened
        // before).
        let nonZero = samples.contains { abs($0) > 0.01 }
        XCTAssertTrue(nonZero, "Resampled buffer is suspiciously all-silent")
    }

    func testProgressCallbackFiresAndReachesCompletion() async throws {
        let url = try writeStereoSineFixture(durationSeconds: 2.0)
        defer { try? FileManager.default.removeItem(at: url) }

        // Tracker is MainActor-isolated because progress is delivered there.
        actor Tracker {
            private(set) var values: [Double] = []
            func record(_ v: Double) { values.append(v) }
        }
        let tracker = Tracker()

        _ = try await StreamingAudioResampler.resampleToMonoFloat32(
            url: url,
            targetSampleRate: 16_000,
            progress: { value in
                Task { await tracker.record(value) }
            }
        )

        // The progress closure dispatches into `Task { ... }` so the actor
        // sees calls slightly later than the synchronous emission. Drain.
        for _ in 0..<5 { await Task.yield() }
        // Belt-and-braces tiny sleep so the trailing async-record completes
        // even on a heavily loaded CI box. 50 ms is plenty here.
        try await Task.sleep(nanoseconds: 50_000_000)

        let values = await tracker.values
        XCTAssertGreaterThanOrEqual(values.count, 1,
                                    "Progress closure must fire at least once")
        XCTAssertGreaterThanOrEqual(values.last ?? 0, 0.999,
                                    "Final progress value should be >= 0.999, got \(values.last ?? -1)")
        // All values must be in [0, 1].
        for v in values {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    // MARK: - Cancellation

    func testCancellationThrows() async throws {
        // We need the resampler to still be running when we cancel. The
        // simplest way is to cancel BEFORE we ever await the task — Swift
        // structured cancellation propagates pre-cancellation, and the
        // very first thing inside the read loop is `try Task.checkCancellation()`.
        let url = try writeStereoSineFixture(durationSeconds: 5.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task<[Float], Swift.Error> {
            try await StreamingAudioResampler.resampleToMonoFloat32(
                url: url,
                targetSampleRate: 16_000,
                progress: { _ in }
            )
        }
        // Cancel immediately — the first `Task.checkCancellation()` inside
        // the read loop will throw `CancellationError`. This is the
        // intended behavior: a cancel that arrives before processing starts
        // must still abort cleanly.
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled task should have thrown")
        } catch is CancellationError {
            // Expected — Task.checkCancellation throws CancellationError.
        } catch let e as StreamingAudioResampler.Error {
            if case .cancelled = e { /* also acceptable */ }
            else { XCTFail("Unexpected resampler error: \(e)") }
        } catch {
            XCTFail("Unexpected error type on cancel: \(error)")
        }
    }

    // MARK: - Failure modes

    func testBogusURLThrowsOpenFailed() async {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        do {
            _ = try await StreamingAudioResampler.resampleToMonoFloat32(
                url: bogus,
                targetSampleRate: 16_000,
                progress: { _ in }
            )
            XCTFail("Expected openFailed for nonexistent URL")
        } catch let e as StreamingAudioResampler.Error {
            if case .openFailed = e { /* expected */ }
            else { XCTFail("Expected .openFailed, got \(e)") }
        } catch {
            XCTFail("Expected StreamingAudioResampler.Error, got \(error)")
        }
    }
}
