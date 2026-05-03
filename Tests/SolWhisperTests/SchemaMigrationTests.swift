import XCTest
@testable import SolWhisper

final class SchemaMigrationTests: XCTestCase {

    func testMigratesPreV1ToCurrentVersion() throws {
        let json: [String: Any] = ["title": "old meeting"]
        let out = try SchemaMigration.migrate(json)
        XCTAssertEqual(out["schemaVersion"] as? Int, SchemaMigration.currentVersion)
        XCTAssertEqual(out["title"] as? String, "old meeting")
    }

    func testKeepsCurrentVersionUntouched() throws {
        let json: [String: Any] = [
            "schemaVersion": SchemaMigration.currentVersion,
            "title": "current meeting"
        ]
        let out = try SchemaMigration.migrate(json)
        XCTAssertEqual(out["schemaVersion"] as? Int, SchemaMigration.currentVersion)
    }

    func testRejectsUnknownFutureVersion() {
        let json: [String: Any] = [
            "schemaVersion": SchemaMigration.currentVersion + 5,
            "title": "from the future"
        ]
        XCTAssertThrowsError(try SchemaMigration.migrate(json)) { error in
            guard let err = error as? SchemaMigrationError else {
                XCTFail("Expected SchemaMigrationError, got \(error)")
                return
            }
            XCTAssertEqual(err, .unknownFutureVersion(SchemaMigration.currentVersion + 5))
        }
    }

    func testRoundTripsRawJSONData() throws {
        let original: [String: Any] = ["title": "raw bytes"]
        let data = try JSONSerialization.data(withJSONObject: original, options: [])
        let migrated = try SchemaMigration.migrate(rawJSON: data)
        let parsed = try JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, SchemaMigration.currentVersion)
        XCTAssertEqual(parsed?["title"] as? String, "raw bytes")
    }

    func testRejectsMalformedRawJSON() {
        let bogus = Data("not json".utf8)
        XCTAssertThrowsError(try SchemaMigration.migrate(rawJSON: bogus))
    }

    // MARK: - Model defaults stamp current schemaVersion

    func testMeetingDefaultsToCurrentSchemaVersion() {
        let m = Meeting(
            source: .recording,
            transcriptionBackend: "apple",
            folderName: "2026-05-03-test"
        )
        XCTAssertEqual(m.schemaVersion, SchemaMigration.currentVersion)
    }

    func testTranscriptDocumentStampsSchemaVersion() {
        let doc = TranscriptDocument(meetingID: UUID(), segments: [])
        XCTAssertEqual(doc.schemaVersion, SchemaMigration.currentVersion)
    }

    func testSummaryStampsSchemaVersion() {
        let s = Summary(
            skillId: "generic",
            llmProvider: "openrouter",
            llmModel: "anthropic/claude-3-5-sonnet",
            sections: [],
            rawMarkdown: ""
        )
        XCTAssertEqual(s.schemaVersion, SchemaMigration.currentVersion)
    }
}
