import XCTest
@testable import SolWhisper

@MainActor
final class CrashRecoveryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-recovery-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root = tempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - Scan

    func testScanReturnsEmptyWhenNoMeetings() {
        let store = MeetingStore(rootDirectory: tempRoot)
        XCTAssertTrue(CrashRecovery.scan(in: store).isEmpty)
    }

    func testScanIgnoresMeetingsWithoutChunksFolder() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        _ = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "clean")
        XCTAssertTrue(CrashRecovery.scan(in: store).isEmpty,
                      "A finalized meeting (no chunks/) should not be flagged as orphan")
    }

    func testScanFlagsMeetingWithOrphanChunks() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "orphan")
        let chunks = store.folderURL(for: meeting).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        // Drop a single chunk file — no done.flag
        try Data().write(to: chunks.appendingPathComponent("chunk-0000-mic.wav"))

        let orphans = CrashRecovery.scan(in: store)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.meeting.id, meeting.id)
        XCTAssertEqual(orphans.first?.chunkCount, 1)
    }

    func testScanFlagsMeetingWithDoneFlagButNoTranscript() throws {
        // Recording finished (done.flag) but the app died during post-processing
        // before transcript.json was written. This is the crash-during-processing
        // case that used to be silently unrecoverable — it MUST now be flagged.
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "doneNoTranscript")
        let chunks = store.folderURL(for: meeting).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data().write(to: chunks.appendingPathComponent("chunk-0000-mic.wav"))
        try Data().write(to: chunks.appendingPathComponent("done.flag"))

        let orphans = CrashRecovery.scan(in: store)
        XCTAssertEqual(orphans.count, 1, "done.flag without a transcript is an interrupted meeting")
        XCTAssertEqual(orphans.first?.meeting.id, meeting.id)
    }

    func testScanIgnoresCompletedMeetingWithTranscript() throws {
        // A completed meeting always has transcript.json — that (not done.flag)
        // is the true completion signal. It must never be flagged for recovery.
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "completed")
        let folder = store.folderURL(for: meeting)
        let chunks = folder.appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data().write(to: chunks.appendingPathComponent("chunk-0000-mic.wav"))
        try Data().write(to: chunks.appendingPathComponent("done.flag"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("transcript.json"))

        XCTAssertTrue(CrashRecovery.scan(in: store).isEmpty,
                      "transcript.json present — meeting is complete, not an orphan")
    }

    func testScanFlagsCrashDuringProcessingFromStitchedAudio() throws {
        // Crash after stitch (chunks already deleted) but before the transcript
        // was written. The stitched audio survives, so recovery is still possible.
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "stitchedOnly")
        let folder = store.folderURL(for: meeting)
        try Data().write(to: folder.appendingPathComponent("audio.m4a"))

        let orphans = CrashRecovery.scan(in: store)
        XCTAssertEqual(orphans.count, 1, "stitched audio without a transcript is recoverable")
        XCTAssertEqual(orphans.first?.chunkCount, 0, "no chunks survive post-stitch")
    }

    func testScanIgnoresEmptyChunksDirectory() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "emptyChunks")
        let chunks = store.folderURL(for: meeting).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        // No chunk-*-mic.wav files

        XCTAssertTrue(CrashRecovery.scan(in: store).isEmpty,
                      "An empty chunks/ folder should not be flagged — nothing to recover")
    }

    // MARK: - chunkCount

    func testChunkCountCountsOnlyMicChunks() throws {
        let dir = tempRoot.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("chunk-0000-mic.wav"))
        try Data().write(to: dir.appendingPathComponent("chunk-0000-sys.wav"))
        try Data().write(to: dir.appendingPathComponent("chunk-0001-mic.wav"))
        try Data().write(to: dir.appendingPathComponent("chunk-0001-sys.wav"))
        try Data().write(to: dir.appendingPathComponent("chunk-0002.metadata.json"))

        XCTAssertEqual(CrashRecovery.chunkCount(at: dir), 2,
                       "Only -mic.wav chunks should be counted")
    }
}
