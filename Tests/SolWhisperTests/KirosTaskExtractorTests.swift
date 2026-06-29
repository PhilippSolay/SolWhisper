import XCTest
@testable import SolWhisper

/// Stub `LLMClient` that returns a canned string and records the messages it
/// received — so extractor tests run with no live model.
private final class StubLLM: LLMClient, @unchecked Sendable {
    var response: String
    var received: [LLMMessage] = []
    init(response: String) { self.response = response }
    func complete(messages: [LLMMessage], model: String,
                  temperature: Double, maxTokens: Int) async throws -> String {
        received = messages
        return response
    }
}

final class KirosTaskExtractorTests: XCTestCase {

    // MARK: - parse (pure)

    func testParsesWellFormedTasksAndAssignsIdxByPosition() {
        let json = """
        {"tasks":[
          {"title":"Send quote","company":"Acme Studio","category":"Sales",
           "importance":4,"urgency":5,"est":"30m","due":"2026-07-02","energy":"low"},
          {"title":"Book studio time","importance":2}
        ]}
        """
        let tasks = KirosTaskExtractor.parse(json)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].idx, 0)
        XCTAssertEqual(tasks[1].idx, 1)
        XCTAssertEqual(tasks[0].title, "Send quote")
        XCTAssertEqual(tasks[0].est, "30m")
        XCTAssertEqual(tasks[0].due, "2026-07-02")
    }

    func testParsesJSONWrappedInFencesAndProse() {
        let text = """
        Sure! Here are the tasks:
        ```json
        {"tasks":[{"title":"Email the deck"}]}
        ```
        Let me know if you need more.
        """
        let tasks = KirosTaskExtractor.parse(text)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "Email the deck")
    }

    func testGarbageOrEmptyReturnsNoTasks() {
        XCTAssertTrue(KirosTaskExtractor.parse("no json here").isEmpty)
        XCTAssertTrue(KirosTaskExtractor.parse("").isEmpty)
        XCTAssertTrue(KirosTaskExtractor.parse(#"{"tasks":[]}"#).isEmpty)
    }

    func testDropsTasksWithEmptyTitle() {
        let tasks = KirosTaskExtractor.parse(#"{"tasks":[{"title":"   "},{"title":"Real"}]}"#)
        XCTAssertEqual(tasks.map(\.title), ["Real"])
        XCTAssertEqual(tasks[0].idx, 0, "idx must compact after dropping invalid tasks")
    }

    func testNormalizesOutOfRangeAndBadFields() {
        let json = """
        {"tasks":[{"title":"X","importance":9,"urgency":0,"est":"giant",
                   "due":"2026-13-40","energy":"medium"}]}
        """
        let t = KirosTaskExtractor.parse(json)[0]
        XCTAssertNil(t.importance, "9 is out of 1-5 → nil")
        XCTAssertNil(t.urgency, "0 is out of 1-5 → nil")
        XCTAssertNil(t.est, "unknown est bucket → nil")
        XCTAssertNil(t.due, "invalid calendar date → nil")
        XCTAssertEqual(t.energy, "med", "\"medium\" maps to \"med\"")
    }

    func testTolerantIntDecodingFromStringsAndFloats() {
        let t = KirosTaskExtractor.parse(#"{"tasks":[{"title":"X","importance":"4","urgency":3.0}]}"#)[0]
        XCTAssertEqual(t.importance, 4)
        XCTAssertEqual(t.urgency, 3)
    }

    func testCapsTaskCount() {
        let items = (0..<80).map { #"{"title":"T\#($0)"}"# }.joined(separator: ",")
        let tasks = KirosTaskExtractor.parse("{\"tasks\":[\(items)]}")
        XCTAssertEqual(tasks.count, KirosTaskExtractor.maxTasks)
    }

    // MARK: - buildMessages (pure)

    func testPromptInjectsIdentityFrontsAndSummary() {
        let fronts = [KirosFront(code: "AS-SALE", name: "Sales", company: "Acme Studio", importance: 4)]
        let msgs = KirosTaskExtractor.buildMessages(
            template: KirosExtractionPrompt.template,
            summaryMarkdown: "## Action Items\n- Philipp to send the quote",
            meetingTitle: "Bluebird call", today: "2026-06-29",
            identities: ["Philipp", "me"], fronts: fronts)
        let system = msgs[0].content
        XCTAssertEqual(msgs[0].role, .system)
        XCTAssertTrue(system.contains("Philipp / me"), "identities must reach the prompt")
        XCTAssertTrue(system.contains("2026-06-29"))
        XCTAssertTrue(system.contains("AS-SALE"), "fronts taxonomy must reach the prompt")
        XCTAssertEqual(msgs[1].role, .user)
        XCTAssertTrue(msgs[1].content.contains("Bluebird call"))
        XCTAssertTrue(msgs[1].content.contains("send the quote"))
    }

    func testEmptyIdentitiesFallsBackToMe() {
        let msgs = KirosTaskExtractor.buildMessages(
            template: KirosExtractionPrompt.template, summaryMarkdown: "s",
            meetingTitle: "m", today: "2026-06-29", identities: ["  "], fronts: [])
        XCTAssertTrue(msgs[0].content.contains("the user (me)"))
    }

    // MARK: - extract (with stub LLM)

    func testExtractRunsLLMThenParses() async throws {
        let stub = StubLLM(response: #"{"tasks":[{"title":"Ship it","importance":5}]}"#)
        let extractor = KirosTaskExtractor(client: stub, modelID: "test-model")
        let tasks = try await extractor.extract(
            summaryMarkdown: "summary", meetingTitle: "Standup", today: "2026-06-29",
            identities: ["Philipp"], fronts: [])
        XCTAssertEqual(tasks, [KirosTask(idx: 0, title: "Ship it", importance: 5)])
        XCTAssertEqual(stub.received.count, 2, "system + user messages were sent")
    }
}
