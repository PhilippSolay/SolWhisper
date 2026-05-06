import XCTest
@testable import SolWhisper

@MainActor
final class VoiceMatcherTests: XCTestCase {

    // MARK: - Cosine similarity

    func testCosineIdenticalVectorsReturnsOne() {
        let a: [Float] = [0.5, 0.5, 0.5, 0.5]
        let sim = VoiceMatcher.cosine(a, a)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-9)
    }

    func testCosineOrthogonalVectorsReturnsZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        let sim = VoiceMatcher.cosine(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-9)
    }

    func testCosineOppositeVectorsReturnsMinusOne() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        let sim = VoiceMatcher.cosine(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-9)
    }

    func testCosineMismatchedLengthsReturnsZero() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0]
        XCTAssertEqual(VoiceMatcher.cosine(a, b), 0)
    }

    func testCosineEmptyInputReturnsZero() {
        XCTAssertEqual(VoiceMatcher.cosine([], []), 0)
    }

    func testCosineZeroVectorReturnsZero() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(VoiceMatcher.cosine(a, b), 0,
                       "Denominator collapses to zero — must not divide by zero")
    }

    func testCosineNormalizesUnnormalizedInputs() {
        // Cosine should be invariant to magnitude.
        let a: [Float] = [3, 4, 0]            // magnitude 5
        let b: [Float] = [6, 8, 0]            // magnitude 10, same direction
        let sim = VoiceMatcher.cosine(a, b)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-6)
    }

    func testCosineKnownAngle() {
        // 60° between vectors → cosine = 0.5.
        let a: [Float] = [1, 0]
        let b: [Float] = [0.5, 0.866_025_4]   // 60° rotation
        let sim = VoiceMatcher.cosine(a, b)
        XCTAssertEqual(sim, 0.5, accuracy: 1e-4)
    }

    // MARK: - Match threshold (constant guard)

    func testMatchThresholdIsAtSeventyPercent() {
        // Locking in the threshold — if anyone changes it, the test
        // forces a deliberate decision rather than silent drift.
        XCTAssertEqual(VoiceMatcher.matchThreshold, 0.70, accuracy: 1e-9)
    }

    // MARK: - Embedding round-trip via VoiceProfileEmbedder

    func testVoiceProfileEmbedderDataToFloatsRoundTrip() {
        let original: [Float] = (0..<256).map { Float($0) * 0.001 }
        let data = original.withUnsafeBufferPointer { Data(buffer: $0) }
        let restored = VoiceProfileEmbedder.dataToFloats(data, dim: 256)
        XCTAssertEqual(restored.count, 256)
        for i in 0..<256 {
            XCTAssertEqual(restored[i], original[i], accuracy: 1e-9)
        }
    }

    func testVoiceProfileEmbedderDataToFloatsRespectsDim() {
        let original: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        let data = original.withUnsafeBufferPointer { Data(buffer: $0) }
        let restored = VoiceProfileEmbedder.dataToFloats(data, dim: 4)
        XCTAssertEqual(restored, [1, 2, 3, 4],
                       "dim should cap output to first N floats")
    }

    func testVoiceProfileEmbedderDataToFloatsCapsAtAvailableSize() {
        // dim larger than what the data actually contains — must not crash.
        let original: [Float] = [1, 2, 3]
        let data = original.withUnsafeBufferPointer { Data(buffer: $0) }
        let restored = VoiceProfileEmbedder.dataToFloats(data, dim: 999)
        XCTAssertEqual(restored, [1, 2, 3],
                       "Should clamp to actual byte count when dim is too large")
    }

    // MARK: - hasEmbedding flag

    func testHasEmbeddingIsFalseWhenNil() {
        let p = VoiceProfile(name: "Alice")
        XCTAssertFalse(p.hasEmbedding)
    }

    func testHasEmbeddingIsFalseWhenEmpty() {
        var p = VoiceProfile(name: "Alice")
        p.embedding = Data()
        p.embeddingDim = 256
        XCTAssertFalse(p.hasEmbedding)
    }

    func testHasEmbeddingIsFalseWhenDimZero() {
        var p = VoiceProfile(name: "Alice")
        p.embedding = Data([0x00, 0x01, 0x02, 0x03])
        p.embeddingDim = 0
        XCTAssertFalse(p.hasEmbedding)
    }

    func testHasEmbeddingIsTrueWhenPresent() {
        var p = VoiceProfile(name: "Alice")
        let v: [Float] = [0.1, 0.2, 0.3, 0.4]
        p.embedding = v.withUnsafeBufferPointer { Data(buffer: $0) }
        p.embeddingDim = v.count
        XCTAssertTrue(p.hasEmbedding)
    }
}
