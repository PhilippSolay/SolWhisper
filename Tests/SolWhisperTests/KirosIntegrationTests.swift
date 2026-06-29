import XCTest
@testable import SolWhisper

/// `KirosIntegration` pure logic + configuration gate. The `send()` orchestration
/// (LLM + network) is exercised end-to-end at S4, matching how the codebase treats
/// the other integrations (only the value-logic is unit-tested).
@MainActor
final class KirosIntegrationTests: XCTestCase {

    private func cleanup() {
        let d = UserDefaults.standard
        d.removeObject(forKey: KirosIntegration.enabledKey)
        d.removeObject(forKey: KirosIntegration.urlKey)
        d.removeObject(forKey: KirosIntegration.identitiesKey)
        try? KeychainStore.delete(key: KirosIntegration.tokenKeychainKey)
    }

    override func setUp() { super.setUp(); cleanup() }
    override func tearDown() { cleanup(); super.tearDown() }

    // MARK: - identities

    func testIdentitiesMergesNameAndAliasesDedupedOrdered() {
        let ids = KirosIntegration.identities(displayName: "Philipp",
                                              aliases: "me, P.S. , philipp")
        // "philipp" is a case-insensitive dupe of "Philipp" → dropped; order preserved.
        XCTAssertEqual(ids, ["Philipp", "me", "P.S."])
    }

    func testIdentitiesEmptyWhenNothingProvided() {
        XCTAssertEqual(KirosIntegration.identities(displayName: nil, aliases: nil), [])
        XCTAssertEqual(KirosIntegration.identities(displayName: "  ", aliases: ""), [])
    }

    // MARK: - makeRequest

    func testMakeRequestShape() {
        let meeting = Meeting(title: "Bluebird call", source: .recording,
                              transcriptionBackend: "apple", folderName: "bluebird")
        let tasks = [KirosTask(idx: 0, title: "A"), KirosTask(idx: 1, title: "B")]
        let req = KirosIntegration.makeRequest(meeting: meeting, tasks: tasks,
                                               capturedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(req.source, "solwhisper")
        XCTAssertEqual(req.meetingId, meeting.id.uuidString)
        XCTAssertEqual(req.meetingTitle, "Bluebird call")
        XCTAssertFalse(req.capturedAt.isEmpty)
        XCTAssertEqual(req.tasks.map(\.idx), [0, 1])
    }

    func testTodayStringIsISODate() {
        XCTAssertEqual(KirosIntegration.todayString(Date(timeIntervalSince1970: 0)), "1970-01-01")
    }

    // MARK: - configuration gate

    func testNotConfiguredUntilURLAndTokenPresent() throws {
        XCTAssertFalse(KirosIntegration.isConfigured, "nothing set")

        UserDefaults.standard.set("https://kairos.solay.cloud", forKey: KirosIntegration.urlKey)
        XCTAssertFalse(KirosIntegration.isConfigured, "URL but no token")

        try KeychainStore.set("tok_123", forKey: KirosIntegration.tokenKeychainKey)
        XCTAssertTrue(KirosIntegration.isConfigured, "URL + token present")
    }

    func testEnabledRequiresToggleAndConfig() throws {
        UserDefaults.standard.set("https://kairos.solay.cloud", forKey: KirosIntegration.urlKey)
        try KeychainStore.set("tok_123", forKey: KirosIntegration.tokenKeychainKey)
        XCTAssertFalse(KirosIntegration.isEnabled, "configured but toggle off")

        UserDefaults.standard.set(true, forKey: KirosIntegration.enabledKey)
        XCTAssertTrue(KirosIntegration.isEnabled)

        // Toggle on but unconfigured → still disabled.
        try KeychainStore.delete(key: KirosIntegration.tokenKeychainKey)
        XCTAssertFalse(KirosIntegration.isEnabled, "toggle on but no token")
    }
}
