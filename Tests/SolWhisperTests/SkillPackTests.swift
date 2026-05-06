import XCTest
@testable import SolWhisper

final class SkillPackTests: XCTestCase {

    // MARK: - Frontmatter parsing

    func testParseModuleWithFrontmatterExtractsKeysAndBody() {
        let raw = """
        ---
        name: Client Discovery
        description: Sales discovery call summary
        ---

        # Body starts here

        Some content.
        """
        let mod = SkillPack.parseModule(raw)
        XCTAssertEqual(mod.frontmatter["name"], "Client Discovery")
        XCTAssertEqual(mod.frontmatter["description"], "Sales discovery call summary")
        XCTAssertTrue(mod.body.hasPrefix("# Body starts here"))
        XCTAssertEqual(mod.name, "Client Discovery")
        XCTAssertEqual(mod.description, "Sales discovery call summary")
    }

    func testParseModuleWithoutFrontmatterReturnsRawBody() {
        let raw = "Just a body with no fences.\n\nLine two."
        let mod = SkillPack.parseModule(raw)
        XCTAssertTrue(mod.frontmatter.isEmpty)
        XCTAssertEqual(mod.body, raw)
        XCTAssertEqual(mod.name, "")
    }

    func testParseModuleWithEmptyFrontmatterStillParsesBody() {
        let raw = """
        ---
        ---
        Body line.
        """
        let mod = SkillPack.parseModule(raw)
        XCTAssertTrue(mod.frontmatter.isEmpty)
        XCTAssertEqual(mod.body, "Body line.")
    }

    func testParseModuleHandlesValuesWithColons() {
        // The simple parser splits on the FIRST colon, so a value like
        // "url: https://x.com" must keep its colon intact.
        let raw = """
        ---
        url: https://example.com:8080/path
        ---

        Body.
        """
        let mod = SkillPack.parseModule(raw)
        XCTAssertEqual(mod.frontmatter["url"], "https://example.com:8080/path")
    }

    func testParseModuleTrimsWhitespaceFromKeysAndValues() {
        let raw = """
        ---
            name   :   Padded Name
        ---
        x
        """
        let mod = SkillPack.parseModule(raw)
        XCTAssertEqual(mod.frontmatter["name"], "Padded Name")
    }

    // MARK: - renderPrompt

    private func makePack(typeIDs: [String]) -> SkillPack {
        let parent = SkillModule(
            frontmatter: ["name": "Meeting Summary",
                          "description": "Auto-classify meeting summaries"],
            body: "PARENT_BODY: classify then summarize."
        )
        let shared = [
            SharedSkillModule(filename: "extract-decisions.md",
                               module: SkillModule(frontmatter: [:],
                                                    body: "SHARED_DECISIONS"))
        ]
        var types: [String: SkillModule] = [:]
        for tid in typeIDs {
            types[tid] = SkillModule(frontmatter: ["name": tid],
                                      body: "TYPE_BODY_\(tid)")
        }
        return SkillPack(id: "meeting-summary",
                         parent: parent,
                         shared: shared,
                         types: types,
                         isBuiltIn: true)
    }

    func testRenderPromptWithKnownMeetingTypeOnlyIncludesThatType() {
        let pack = makePack(typeIDs: ["client-discovery", "standup", "retro"])
        let (system, user) = pack.renderPrompt(
            meetingType: "client-discovery",
            transcript: "T",
            participants: ["Alice", "Bob"]
        )
        XCTAssertTrue(system.contains("PARENT_BODY"))
        XCTAssertTrue(system.contains("SHARED_DECISIONS"))
        XCTAssertTrue(system.contains("TYPE_BODY_client-discovery"))
        XCTAssertFalse(system.contains("TYPE_BODY_standup"),
                       "Only the chosen type should be in the prompt")
        XCTAssertFalse(system.contains("TYPE_BODY_retro"))
        XCTAssertTrue(system.contains("Skip Step 1"),
                      "Pre-selected branch must instruct LLM to skip classification")
        XCTAssertTrue(user.contains("Alice, Bob"))
        XCTAssertTrue(user.contains("<transcript>"))
        XCTAssertTrue(user.contains("T"))
    }

    func testRenderPromptWithoutMeetingTypeBundlesAllTypes() {
        let pack = makePack(typeIDs: ["client-discovery", "standup", "retro"])
        let (system, _) = pack.renderPrompt(
            meetingType: nil,
            transcript: "T",
            participants: []
        )
        XCTAssertTrue(system.contains("TYPE_BODY_client-discovery"))
        XCTAssertTrue(system.contains("TYPE_BODY_standup"))
        XCTAssertTrue(system.contains("TYPE_BODY_retro"))
        XCTAssertTrue(system.contains("auto-classify"),
                      "Auto-classify branch must keep Step 1 intact")
    }

    func testRenderPromptWithUnknownMeetingTypeFallsBackToAllTypes() {
        let pack = makePack(typeIDs: ["standup", "retro"])
        let (system, _) = pack.renderPrompt(
            meetingType: "this-type-does-not-exist",
            transcript: "T",
            participants: ["Alice"]
        )
        // Should fall back to bundling everything rather than blocking.
        XCTAssertTrue(system.contains("TYPE_BODY_standup"))
        XCTAssertTrue(system.contains("TYPE_BODY_retro"))
        XCTAssertTrue(system.contains("auto-classify"))
    }

    func testRenderPromptEmptyParticipantsShowsNotSpecified() {
        let pack = makePack(typeIDs: ["standup"])
        let (_, user) = pack.renderPrompt(
            meetingType: "standup",
            transcript: "T",
            participants: []
        )
        XCTAssertTrue(user.contains("not specified"))
    }

    func testRenderPromptIncludesContextBlockWhenProvided() {
        let pack = makePack(typeIDs: ["standup"])
        let (_, user) = pack.renderPrompt(
            meetingType: "standup",
            transcript: "T",
            participants: ["Alice"],
            context: "Background: Q1 OKRs"
        )
        XCTAssertTrue(user.contains("Background you should know"))
        XCTAssertTrue(user.contains("Q1 OKRs"))
    }

    func testRenderPromptOmitsContextBlockWhenEmptyOrWhitespace() {
        let pack = makePack(typeIDs: ["standup"])
        let (_, user1) = pack.renderPrompt(
            meetingType: "standup", transcript: "T", participants: ["A"], context: nil
        )
        let (_, user2) = pack.renderPrompt(
            meetingType: "standup", transcript: "T", participants: ["A"], context: "   \n  "
        )
        XCTAssertFalse(user1.contains("Background you should know"))
        XCTAssertFalse(user2.contains("Background you should know"))
    }

    func testTypeIDsSortedAlphabetically() {
        let pack = makePack(typeIDs: ["zulu", "alpha", "mike"])
        XCTAssertEqual(pack.typeIDs, ["alpha", "mike", "zulu"])
    }
}
