import XCTest
@testable import SolWhisper

final class DiarizationMapperTests: XCTestCase {

    // MARK: - Helpers

    private func segs(_ tuples: [(Double, Double, String)]) -> [SpeakerSegment] {
        tuples.map { SpeakerSegment(start: $0.0, end: $0.1, speakerID: $0.2) }
    }

    private func tx(_ tuples: [(Double, Double)]) -> [TranscriptSegment] {
        tuples.map { TranscriptSegment(start: $0.0, end: $0.1, text: "x") }
    }

    // MARK: - normalizeToLetters

    func testNormalizeToLettersAssignsAInOrderOfFirstAppearance() {
        let input = segs([
            (0, 1, "spk_2"),    // first → A
            (1, 2, "spk_0"),    // second → B
            (2, 3, "spk_2"),    // already mapped → A
            (3, 4, "spk_5")     // third unique → C
        ])
        let out = DiarizationMapper.normalizeToLetters(input)
        XCTAssertEqual(out.map(\.speakerID), ["A", "B", "A", "C"])
    }

    func testNormalizeToLettersPreservesAlreadyLetterIDs() {
        let input = segs([(0, 1, "A"), (1, 2, "B"), (2, 3, "A")])
        let out = DiarizationMapper.normalizeToLetters(input)
        // Whatever the strings are, first-appearance becomes "A", second "B".
        XCTAssertEqual(out.map(\.speakerID), ["A", "B", "A"])
    }

    func testNormalizeToLettersHandlesMoreThan26Speakers() {
        var input: [SpeakerSegment] = []
        for i in 0..<28 {
            input.append(SpeakerSegment(start: Double(i), end: Double(i)+1, speakerID: "id_\(i)"))
        }
        let out = DiarizationMapper.normalizeToLetters(input)
        XCTAssertEqual(out[0].speakerID, "A")
        XCTAssertEqual(out[25].speakerID, "Z")
        // Overflow safeguard: 27th unique speaker uses S\(ordinal) form.
        XCTAssertEqual(out[26].speakerID, "S26")
        XCTAssertEqual(out[27].speakerID, "S27")
    }

    func testNormalizeToLettersPreservesStartEndTimes() {
        let input = segs([(0.5, 1.7, "x"), (2.0, 4.5, "y")])
        let out = DiarizationMapper.normalizeToLetters(input)
        XCTAssertEqual(out[0].start, 0.5)
        XCTAssertEqual(out[0].end,   1.7)
        XCTAssertEqual(out[1].start, 2.0)
        XCTAssertEqual(out[1].end,   4.5)
    }

    // MARK: - apply (overlap mapping)

    func testApplyEmptySpeakerSegmentsLeavesTranscriptUnchanged() {
        let transcript = tx([(0, 1), (1, 2)])
        let out = DiarizationMapper.apply([], to: transcript)
        XCTAssertEqual(out, transcript)
        XCTAssertNil(out[0].speakerID)
        XCTAssertNil(out[1].speakerID)
    }

    func testApplyTagsSegmentWithMajorityOverlapSpeaker() {
        // Speaker A covers 0–10, speaker B covers 10–20.
        // Transcript segment 0–9 overlaps A entirely → A.
        let speakers = segs([(0, 10, "A"), (10, 20, "B")])
        let transcript = tx([(0, 9)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertEqual(out[0].speakerID, "A")
    }

    func testApplyMixedOverlapPicksMajoritySpeaker() {
        // Transcript segment 0–10. A covers 0–7 (70%), B covers 7–10 (30%).
        let speakers = segs([(0, 7, "A"), (7, 10, "B")])
        let transcript = tx([(0, 10)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertEqual(out[0].speakerID, "A")
    }

    func testApplyBelowTwentyPercentThresholdLeavesUntagged() {
        // Transcript segment 0–10. Only one speaker, with 1.5s overlap = 15%.
        // Should stay nil because threshold is 20%.
        let speakers = segs([(0, 1.5, "A")])
        let transcript = tx([(0, 10)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertNil(out[0].speakerID, "15% overlap shouldn't pass the 20% threshold")
    }

    func testApplyAtTwentyPercentThresholdTagsSegment() {
        // 2.0s overlap on a 10s segment = 20% — must pass (>=).
        let speakers = segs([(0, 2.0, "A")])
        let transcript = tx([(0, 10)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertEqual(out[0].speakerID, "A")
    }

    func testApplyNoOverlapAtAllLeavesUntagged() {
        // Transcript segment 5–10, speaker only covers 0–4.
        let speakers = segs([(0, 4, "A")])
        let transcript = tx([(5, 10)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertNil(out[0].speakerID)
    }

    func testApplyMultipleSpeakerSegmentsAggregateForSameLetter() {
        // Speaker A appears in two chunks that together exceed 20%.
        // Either chunk alone is below threshold.
        let speakers = segs([
            (0, 1.0, "A"),    // 10% of 10s
            (5, 6.5, "A")     // 15% of 10s — together 25%
        ])
        let transcript = tx([(0, 10)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        XCTAssertEqual(out[0].speakerID, "A",
                       "Aggregated overlap from same speaker must clear threshold")
    }

    func testApplyPreservesNonSpeakerFields() {
        let original = TranscriptSegment(start: 0, end: 10, text: "hello",
                                          confidence: 0.9, speaker: .me,
                                          cleanedText: "Hello.", speakerID: nil)
        let speakers = segs([(0, 10, "A")])
        let out = DiarizationMapper.apply(speakers, to: [original])
        XCTAssertEqual(out[0].text, "hello")
        XCTAssertEqual(out[0].cleanedText, "Hello.")
        XCTAssertEqual(out[0].confidence, 0.9)
        XCTAssertEqual(out[0].speaker, .me)
        XCTAssertEqual(out[0].speakerID, "A")
        XCTAssertEqual(out[0].id, original.id)
    }

    func testApplyZeroLengthSegmentDoesNotCrash() {
        // Edge case: degenerate transcript segment with start == end.
        let speakers = segs([(0, 5, "A")])
        let transcript = tx([(2, 2)])
        let out = DiarizationMapper.apply(speakers, to: transcript)
        // 0 overlap → stays nil.
        XCTAssertNil(out[0].speakerID)
    }
}
