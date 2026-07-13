import XCTest
@testable import SolWhisper

/// Stub `ImportControlling` that records `begin`/`cancel` and lets the test
/// drive delegate phases by hand — so the queue's serial pump can be exercised
/// without live WhisperKit transcription.
@MainActor
private final class StubImportController: ImportControlling {
    weak var delegate: FileImportControllerDelegate?
    private(set) var begunURLs: [URL] = []
    private(set) var cancelCount = 0

    func begin(audioURL: URL) { begunURLs.append(audioURL) }

    func cancel() {
        cancelCount += 1
        // Mirror the real controller: emit `.cancelling` synchronously. The
        // terminal `.failed("Cancelled")` is emitted separately by the test to
        // model the transcription task finishing its teardown afterwards.
        delegate?.fileImport(self, didEnter: .cancelling)
    }

    /// Drive an arbitrary phase into the queue as if the controller emitted it.
    func emit(_ phase: FileImportController.Phase) {
        delegate?.fileImport(self, didEnter: phase)
    }
}

/// Records every controller the queue's factory produces, in order, so the test
/// can drive each one.
@MainActor
private final class ControllerFactory {
    private(set) var created: [StubImportController] = []
    func make(_ store: MeetingStore) -> any ImportControlling {
        let c = StubImportController()
        created.append(c)
        return c
    }
}

@MainActor
final class ImportQueueTests: XCTestCase {

    private var tempRoot: URL!
    private var store: MeetingStore!
    private var factory: ControllerFactory!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-importqueue-tests-\(UUID().uuidString)", isDirectory: true)
        store = MeetingStore(rootDirectory: tempRoot)
        factory = ControllerFactory()
    }

    override func tearDown() async throws {
        if let root = tempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func makeQueue() -> ImportQueue {
        let factory = self.factory!
        return ImportQueue(store: store, makeController: { factory.make($0) })
    }

    private func wav(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).wav") }

    private func donePhase(segments: Int = 1) -> FileImportController.Phase {
        .done(meetingID: UUID(),
              folderURL: URL(fileURLWithPath: "/tmp"),
              segmentCount: segments,
              audioSeconds: 10)
    }

    // MARK: - enqueue / dedup / rejection

    func testEnqueueStartsOnlyTheFirstItem() {
        let queue = makeQueue()
        let added = queue.enqueue([wav("a"), wav("b")])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(factory.created.count, 1, "serial: only the first item starts")
        XCTAssertEqual(factory.created.first?.begunURLs, [wav("a")])
        XCTAssertTrue(queue.isProcessing)
    }

    func testDedupesWithinAndAcrossDrops() {
        let queue = makeQueue()
        XCTAssertEqual(queue.enqueue([wav("a"), wav("a")]), 1, "duplicate within a drop is ignored")
        XCTAssertEqual(queue.enqueue([wav("a")]), 0, "duplicate of an in-flight item is ignored")
        XCTAssertEqual(queue.items.filter { $0.audioURL == wav("a") }.count, 1)
    }

    func testUnsupportedFileBecomesFailedRowListingFormats() {
        let queue = makeQueue()
        let added = queue.enqueue([URL(fileURLWithPath: "/tmp/notes.txt")])
        XCTAssertEqual(added, 0, "unsupported files aren't counted as enqueued")
        guard case .failed(let msg)? = queue.items.first?.status else {
            return XCTFail("Expected a failed row for the unsupported file")
        }
        // Fix #6: the rejection must list what IS importable, not dead-end.
        XCTAssertTrue(msg.contains("WAV"), "rejection must list supported formats: \(msg)")
        XCTAssertTrue(msg.contains("MP3"))
        XCTAssertNil(factory.created.first, "no controller runs for a rejection-only drop")
    }

    // MARK: - serial pump: advance + continue-on-failure

    func testAdvancesToNextItemOnDone() {
        let queue = makeQueue()
        queue.enqueue([wav("a"), wav("b")])
        factory.created[0].emit(donePhase())
        XCTAssertEqual(factory.created.count, 2, "second item starts after the first finishes")
        XCTAssertEqual(factory.created[1].begunURLs, [wav("b")])
        XCTAssertEqual(queue.items[0].status, .done)
    }

    func testContinuesToNextItemAfterFailure() {
        let queue = makeQueue()
        queue.enqueue([wav("a"), wav("b")])
        factory.created[0].emit(.failed(message: "boom"))
        XCTAssertEqual(factory.created.count, 2, "a failure must not stall the queue")
        XCTAssertEqual(queue.items[0].status, .failed("boom"))
        XCTAssertEqual(factory.created[1].begunURLs, [wav("b")])
    }

    func testBatchReportFiresOnceOnDrain() {
        let queue = makeQueue()
        var reports: [ImportQueue.BatchReport] = []
        queue.onBatchFinished = { reports.append($0) }
        queue.enqueue([wav("a")])
        factory.created[0].emit(donePhase(segments: 3))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.succeeded, ["a.wav"])
        XCTAssertFalse(queue.isProcessing)
    }

    // MARK: - cancel serialization (fix #3)

    func testCancelDoesNotStartNextUntilTeardownCompletes() {
        let queue = makeQueue()
        queue.enqueue([wav("a"), wav("b")])
        let first = factory.created[0]
        let activeID = queue.items.first(where: { $0.status == .active })!.id

        queue.cancel(activeID)   // → controller.cancel() → emits .cancelling
        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(factory.created.count, 1,
                       "the next item must NOT start while the cancelled task is still tearing down")
        XCTAssertTrue(queue.isProcessing, "queue stays busy during teardown")

        // Task finishes unwinding → terminal phase → only NOW does the next start.
        first.emit(.failed(message: "Cancelled"))
        XCTAssertEqual(factory.created.count, 2, "next item starts only after the terminal phase")
        XCTAssertEqual(factory.created[1].begunURLs, [wav("b")])
        XCTAssertEqual(queue.items[0].status, .cancelled)
    }
}
