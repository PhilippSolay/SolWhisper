import XCTest
@testable import SolWhisper

@MainActor
final class MeetingStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-meeting-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let root = tempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    // MARK: - Slug normalization

    func testSlugNormalizationStripsNonAlphanumerics() {
        XCTAssertEqual(MeetingStore.normalizeSlug("Q1 / Strategy review!"), "q1-strategy-review")
    }

    func testSlugNormalizationCollapsesSeparators() {
        XCTAssertEqual(MeetingStore.normalizeSlug("hello---world___test"), "hello-world-test")
    }

    func testSlugNormalizationFallsBackForEmptyInput() {
        XCTAssertEqual(MeetingStore.normalizeSlug(""), "meeting")
        XCTAssertEqual(MeetingStore.normalizeSlug("///"), "meeting")
    }

    func testSlugNormalizationCapsLength() {
        let long = String(repeating: "a", count: 200)
        XCTAssertLessThanOrEqual(MeetingStore.normalizeSlug(long).count, 60)
    }

    // MARK: - CRUD lifecycle

    func testCreateProducesFolderAndMeetingJSON() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(
            source: .recording,
            title: "Demo",
            transcriptionBackend: "whisperkit-base.en",
            folderSlug: "demo"
        )

        XCTAssertEqual(store.meetings.count, 1)
        XCTAssertTrue(meeting.folderName.hasSuffix("-demo"))

        let folder = store.folderURL(for: meeting)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let json = folder.appendingPathComponent("meeting.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))

        let log = folder.appendingPathComponent("session.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path),
                      "session.log should be populated immediately")
    }

    func testCreateAvoidsCollisionByAppendingTimeAndCounter() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let first  = try store.create(source: .import, title: "A", transcriptionBackend: "wk", folderSlug: "podcast")
        let second = try store.create(source: .import, title: "B", transcriptionBackend: "wk", folderSlug: "podcast")
        let third  = try store.create(source: .import, title: "C", transcriptionBackend: "wk", folderSlug: "podcast")
        XCTAssertNotEqual(first.folderName, second.folderName)
        XCTAssertNotEqual(second.folderName, third.folderName)
        XCTAssertEqual(Set([first.folderName, second.folderName, third.folderName]).count, 3)
    }

    func testUpdatePersistsFieldsAndBumpsUpdatedAt() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        var meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "x")
        let originalUpdate = meeting.updatedAt

        meeting.title = "Renamed"
        meeting.durationSeconds = 123.4
        // Sleep a hair so the second timestamp is strictly newer.
        runAsync { try await Task.sleep(nanoseconds: 5_000_000) }
        try store.update(meeting)

        XCTAssertEqual(store.meetings.first?.title, "Renamed")
        XCTAssertEqual(store.meetings.first?.durationSeconds, 123.4)
        XCTAssertGreaterThan(store.meetings.first!.updatedAt, originalUpdate)
    }

    func testDeleteRemovesFromMemoryAndTrashesFolder() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "to-delete")
        let folder = store.folderURL(for: meeting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try store.delete(meeting)

        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path),
                       "Folder should be moved to Trash, not retained at original path")
    }

    func testLoadAllParsesEveryMeetingFolder() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        _ = try store.create(source: .recording, title: "First",  transcriptionBackend: "wk", folderSlug: "alpha")
        _ = try store.create(source: .import,    title: "Second", transcriptionBackend: "wk", folderSlug: "beta")

        let reloaded = MeetingStore(rootDirectory: tempRoot)
        try reloaded.loadAll()
        XCTAssertEqual(reloaded.meetings.count, 2)
        XCTAssertEqual(Set(reloaded.meetings.map(\.title)), ["First", "Second"])
    }

    func testLoadAllSkipsMalformedMetaWithoutCrashing() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        _ = try store.create(source: .recording, title: "Real", transcriptionBackend: "wk", folderSlug: "real")

        // Plant a folder with a malformed meeting.json
        let bogusFolder = tempRoot.appendingPathComponent("2026-01-01-bogus", isDirectory: true)
        try FileManager.default.createDirectory(at: bogusFolder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bogusFolder.appendingPathComponent("meeting.json"))

        let reloaded = MeetingStore(rootDirectory: tempRoot)
        try reloaded.loadAll()
        XCTAssertEqual(reloaded.meetings.count, 1, "Bogus folder must be skipped, not crash the load")
        XCTAssertEqual(reloaded.meetings.first?.title, "Real")
    }

    // MARK: - Transcript I/O

    func testTranscriptRoundTrip() throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .import, transcriptionBackend: "wk", folderSlug: "tx-round")

        let segments = [
            TranscriptSegment(start: 0, end: 1.5, text: "hello world"),
            TranscriptSegment(start: 1.5, end: 3.0, text: "second segment", speaker: .me)
        ]
        let doc = TranscriptDocument(meetingID: meeting.id, segments: segments)
        try store.writeTranscript(doc, for: meeting)
        try store.writeTranscriptMarkdown("# title\n\nbody", for: meeting)

        let loaded = try store.loadTranscript(for: meeting)
        XCTAssertEqual(loaded?.segments.count, 2)
        XCTAssertEqual(loaded?.segments.first?.text, "hello world")
    }

    // MARK: - tiny helper to await sleep inside a sync test

    private func runAsync(_ work: @escaping () async throws -> Void) {
        let exp = expectation(description: "async block")
        Task {
            try? await work()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
