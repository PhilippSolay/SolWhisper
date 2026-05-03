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

    func testScanIgnoresMeetingWithDoneFlag() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "done")
        let chunks = store.folderURL(for: meeting).appendingPathComponent("chunks")
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data().write(to: chunks.appendingPathComponent("chunk-0000-mic.wav"))
        try Data().write(to: chunks.appendingPathComponent("done.flag"))

        XCTAssertTrue(CrashRecovery.scan(in: store).isEmpty,
                      "done.flag means clean stop — should not appear in orphan scan")
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
