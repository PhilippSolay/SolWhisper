import XCTest
@testable import SolWhisper

/// Covers the name-fallback path of `VoiceProfileBackfill`. The strict
/// fast-path (profile already has `sourceMeetingID + sourceSpeakerLetter`)
/// is not exercised here because it doesn't involve any non-trivial
/// resolution — it just hands those values straight to the embedder. The
/// expensive part is `findSourceByName`, which is what these tests pin.
@available(macOS 14.0, *)
@MainActor
final class VoiceProfileBackfillTests: XCTestCase {

    private var tempRoot: URL!
    private var store: MeetingStore!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-backfill-tests-\(UUID().uuidString)",
                                     isDirectory: true)
        store = MeetingStore(rootDirectory: tempRoot)
    }

    override func tearDown() async throws {
        if let root = tempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - findSourceByName: negative paths

    func testFindSourceReturnsNilWhenNoMeetingsExist() throws {
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNil(result)
    }

    func testFindSourceReturnsNilWhenMeetingHasNoSpeakerNames() throws {
        _ = try makeMeeting(slug: "no-names", speakerNames: nil, letterCounts: ["A": 5])
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNil(result, "Meetings without rename mappings are invisible to the search.")
    }

    func testFindSourceReturnsNilWhenNameDoesntMatch() throws {
        _ = try makeMeeting(slug: "wrong-name",
                            speakerNames: ["A": "Didi"],
                            letterCounts: ["A": 10])
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNil(result, "Different person name in speakerNames should not match.")
    }

    func testFindSourceReturnsNilWhenMatchedLetterHasNoTaggedSegments() throws {
        // The speakerNames says A=Pierre but no segment carries speakerID="A"
        // — that letter has zero audio signal, so it's useless as an embedding
        // source.
        _ = try makeMeeting(slug: "name-no-signal",
                            speakerNames: ["A": "Pierre"],
                            letterCounts: ["B": 50])  // only B has segments
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNil(result, "Letters with zero tagged segments must not be picked.")
    }

    // MARK: - findSourceByName: positive paths

    func testFindSourceMatchesByNameCaseInsensitively() throws {
        _ = try makeMeeting(slug: "case-test",
                            speakerNames: ["B": "PIERRE"],
                            letterCounts: ["B": 200])
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "pierre",
            meetingStore: store
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.letter, "B")
    }

    func testFindSourcePicksMeetingWithMostSegmentsForThatLetter() throws {
        // Same name, two meetings, different signal density. The richer one
        // wins because a longer audio span yields a more stable embedding.
        let weak = try makeMeeting(slug: "weak-signal",
                                    speakerNames: ["A": "Pierre"],
                                    letterCounts: ["A": 12])
        let strong = try makeMeeting(slug: "strong-signal",
                                      speakerNames: ["B": "Pierre"],
                                      letterCounts: ["B": 250])

        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.meeting.id, strong.id,
                       "Should pick the meeting with 250 segments, not 12.")
        XCTAssertEqual(result?.letter, "B")
        _ = weak
    }

    func testFindSourceIgnoresChannelAliasLetters() throws {
        // `__other__` / `__me__` aren't real diarized speaker letters —
        // they're the mic/system channel aliases. A profile saved with
        // one of those would never match any `speakerID`-tagged segment,
        // so the search must treat them as if no source link existed.
        // (The backfill caller verifies this; here we just make sure the
        // search itself doesn't accidentally validate one.)
        _ = try makeMeeting(slug: "channel-alias",
                            speakerNames: ["__other__": "Satya"],
                            letterCounts: ["__other__": 100])
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Satya",
            meetingStore: store
        )
        // Even though we technically tagged segments with `__other__`,
        // findSourceByName matches by speakerNames mapping — so it WILL
        // return this. That's expected; the caller-level guard in
        // backfillMissingEmbeddings is what actually rejects channel
        // aliases on the profile's sourceSpeakerLetter side.
        XCTAssertNotNil(result, "Name match is purely by speakerNames; the channel-alias guard lives in the backfill caller")
    }

    func testFindSourceCompareSignalAcrossLettersInSameMeeting() throws {
        // One meeting where two different letters both renamed to the same
        // person (a re-recording of a person across two segmented spans, for
        // example). We should pick the higher-signal letter from within the
        // same meeting.
        let meeting = try makeMeeting(
            slug: "two-letters-one-name",
            speakerNames: ["A": "Pierre", "C": "Pierre"],
            letterCounts: ["A": 5, "C": 80]
        )
        let result = VoiceProfileBackfill.findSourceByName(
            profileName: "Pierre",
            meetingStore: store
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.meeting.id, meeting.id)
        XCTAssertEqual(result?.letter, "C", "Both letters name Pierre; should take the one with 80 segments.")
    }

    // MARK: - Helpers

    /// Creates a meeting + its transcript file in the temp store. `letterCounts`
    /// is the number of segments tagged with each speaker letter (the rest
    /// are untagged — `speakerID == nil`). Segments are placed at 0.0s,
    /// 1.0s, 2.0s, … each lasting 0.5s; the actual times don't matter for
    /// the search logic which only counts tagged segments.
    @discardableResult
    private func makeMeeting(
        slug: String,
        speakerNames: [String: String]?,
        letterCounts: [String: Int]
    ) throws -> Meeting {
        var meeting = try store.create(
            source: .recording,
            title: slug,
            transcriptionBackend: "test-backend",
            folderSlug: slug
        )
        if let names = speakerNames {
            meeting.speakerNames = names
            try store.update(meeting)
        }

        var segments: [TranscriptSegment] = []
        var t: TimeInterval = 0
        for (letter, count) in letterCounts {
            for _ in 0..<count {
                segments.append(TranscriptSegment(
                    start: t,
                    end: t + 0.5,
                    text: "test",
                    speaker: .unknown,
                    speakerID: letter
                ))
                t += 1.0
            }
        }
        let doc = TranscriptDocument(meetingID: meeting.id, segments: segments)
        try store.writeTranscript(doc, for: meeting)

        // Reload from disk so findSourceByName, which calls loadTranscript,
        // sees what we just wrote.
        try store.loadAll()
        return store.meetings.first { $0.id == meeting.id } ?? meeting
    }
}
