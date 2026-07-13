import XCTest
@testable import SolWhisper

/// Exercises `MeetingPostProcessor.run` on its pure disk path — every optional
/// stage (clean/diarize/summarize/integrate) disabled, so there is no LLM,
/// diarization, integration, or network. That isolates the completion-marker
/// behaviour added for the "crash after transcript, before summary" fix.
@MainActor
final class MeetingPostProcessorTests: XCTestCase {

    private var tempRoot: URL!
    private var saved: [String: Any] = [:]
    private let toggleKeys = ["meetingsAutoCleanTranscript", "meetingsAutoDiarize",
                              "meetingsAutoSummarize", "meetingsAutoIntegrate"]

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-postproc-tests-\(UUID().uuidString)", isDirectory: true)
        for key in toggleKeys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in toggleKeys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let root = tempRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }

    private func marker(for meeting: Meeting, in store: MeetingStore) -> URL {
        store.folderURL(for: meeting)
            .appendingPathComponent(MeetingPostProcessor.completionMarkerFilename)
    }

    func testRunWritesCompletionMarkerAtEnd() async throws {
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "markerRun")

        let result = await MeetingPostProcessor.run(
            meeting: meeting,
            segments: [TranscriptSegment(start: 0, end: 1, text: "Hello")],
            diarizationAudioURL: store.folderURL(for: meeting).appendingPathComponent("audio.m4a"),
            store: store,
            setPhase: { _ in }
        )

        XCTAssertTrue(result.completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(for: meeting, in: store).path),
                      "run() must write the completion marker on success")
        XCTAssertTrue(CrashRecovery.incompletePostProcessing(in: store).isEmpty,
                      "a fully-processed meeting is not an incomplete-post-processing candidate")
    }

    func testRunBailsWithoutMarkerWhenMeetingDeletedMidRun() async throws {
        // Folder removed before writes → the checkpoint bails: no transcript, no
        // marker, and the deleted meeting is not resurrected.
        let store = MeetingStore(rootDirectory: tempRoot)
        let meeting = try store.create(source: .recording, transcriptionBackend: "wk", folderSlug: "deletedMidRun")
        try store.delete(meeting)

        let result = await MeetingPostProcessor.run(
            meeting: meeting,
            segments: [TranscriptSegment(start: 0, end: 1, text: "Hi")],
            diarizationAudioURL: store.folderURL(for: meeting).appendingPathComponent("audio.m4a"),
            store: store,
            setPhase: { _ in }
        )

        XCTAssertFalse(result.completed, "a deleted meeting must not be resurrected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(for: meeting, in: store).path))
    }
}
