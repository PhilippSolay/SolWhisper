import XCTest
@testable import SolWhisper

/// Tests for `IntegrationFanout.Result` — the small value type returned
/// from the fanout dispatcher. Pure data, but the `summary` / `isEmpty`
/// helpers feed UI strings and a button enable-state, so a regression
/// here is user-visible.
///
/// `IntegrationFanout` is `@MainActor`-isolated, so this test class is too.
@MainActor
final class IntegrationFanoutResultTests: XCTestCase {

    // MARK: - isEmpty

    func testIsEmptyWhenAllArraysEmpty() {
        let result = IntegrationFanout.Result(sent: [], failed: [], skipped: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.summary, "")
    }

    func testSkippedDoesNotAffectIsEmpty() {
        // Skipped is informational only — a result with only skipped entries
        // is still "empty" from the user's perspective: nothing happened.
        let result = IntegrationFanout.Result(
            sent: [],
            failed: [],
            skipped: ["Hermes", "Obsidian"]
        )
        XCTAssertTrue(result.isEmpty,
                      "Skipped entries should not flip isEmpty to false")
    }

    func testIsNotEmptyWhenSomethingSent() {
        let result = IntegrationFanout.Result(
            sent: ["Hermes"],
            failed: [],
            skipped: []
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testIsNotEmptyWhenSomethingFailed() {
        let result = IntegrationFanout.Result(
            sent: [],
            failed: ["Obsidian"],
            skipped: []
        )
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - summary

    func testSummaryWithOnlySent() {
        let result = IntegrationFanout.Result(
            sent: ["Hermes", "Obsidian"],
            failed: [],
            skipped: []
        )
        XCTAssertEqual(result.summary, "sent: Hermes, Obsidian")
        XCTAssertFalse(result.summary.contains("failed:"))
    }

    func testSummaryWithOnlyFailed() {
        let result = IntegrationFanout.Result(
            sent: [],
            failed: ["Hermes"],
            skipped: []
        )
        XCTAssertEqual(result.summary, "failed: Hermes")
        XCTAssertFalse(result.summary.contains("sent:"))
    }

    func testSummaryWithMixOfSentAndFailed() {
        let result = IntegrationFanout.Result(
            sent: ["Hermes"],
            failed: ["Obsidian"],
            skipped: []
        )
        XCTAssertEqual(result.summary, "sent: Hermes · failed: Obsidian")
        XCTAssertTrue(result.summary.contains("sent: Hermes"))
        XCTAssertTrue(result.summary.contains("failed: Obsidian"))
        XCTAssertTrue(result.summary.contains(" · "),
                      "sent and failed clauses must be joined with a middle-dot separator")
    }

    func testSummaryIgnoresSkipped() {
        let result = IntegrationFanout.Result(
            sent: ["Hermes"],
            failed: [],
            skipped: ["Obsidian", "MyWebhook"]
        )
        XCTAssertEqual(result.summary, "sent: Hermes")
        XCTAssertFalse(result.summary.contains("Obsidian"),
                       "Skipped names should not appear in the summary string")
        XCTAssertFalse(result.summary.contains("MyWebhook"))
    }

    // MARK: - Equatable conformance

    func testResultIsEquatable() {
        let a = IntegrationFanout.Result(sent: ["X"], failed: ["Y"], skipped: ["Z"])
        let b = IntegrationFanout.Result(sent: ["X"], failed: ["Y"], skipped: ["Z"])
        let c = IntegrationFanout.Result(sent: ["X"], failed: ["Y"], skipped: [])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
