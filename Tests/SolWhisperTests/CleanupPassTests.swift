import XCTest
@testable import SolWhisper

@MainActor
final class CleanupPassTests: XCTestCase {

    // MARK: - Mock LLM client

    /// Records every call so tests can assert on chunking behavior, then
    /// returns whatever the test queued up. Tests that just want a clean
    /// pass-through can use the default `transform` (echo input).
    private actor MockLLMClient: LLMClient {
        /// One element per batch the test expects, in order. Each closure
        /// receives the batch's user-prompt text and returns the raw LLM
        /// response (test controls the JSON shape).
        private var responses: [@Sendable (String) -> String]
        private(set) var callLog: [String] = []

        init(_ responses: [@Sendable (String) -> String]) {
            self.responses = responses
        }

        func complete(messages: [LLMMessage],
                      model: String,
                      temperature: Double,
                      maxTokens: Int) async throws -> String {
            let user = messages.first(where: { $0.role == .user })?.content ?? ""
            callLog.append(user)
            guard !responses.isEmpty else {
                throw LLMError.noChoices
            }
            let next = responses.removeFirst()
            return next(user)
        }

        var calls: [String] { callLog }
    }

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        // Default: filler removal on, others off (deterministic for tests).
        UserDefaults.standard.set(true,  forKey: "polishRemoveFiller")
        UserDefaults.standard.set(false, forKey: "polishFixPunctuation")
        UserDefaults.standard.set(false, forKey: "polishFixGrammar")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "polishRemoveFiller")
        UserDefaults.standard.removeObject(forKey: "polishFixPunctuation")
        UserDefaults.standard.removeObject(forKey: "polishFixGrammar")
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSegments(_ texts: [String]) -> [TranscriptSegment] {
        texts.enumerated().map { (i, t) in
            TranscriptSegment(start: Double(i), end: Double(i) + 1, text: t)
        }
    }

    /// Builds a JSON-object response that returns a fixed cleaned string for
    /// every line index parsed out of the prompt's `[N] …` numbering.
    private func jsonObjectEcho(_ prefix: String) -> @Sendable (String) -> String {
        return { user in
            // Scan for [0], [1], ... to figure out how many lines were sent.
            let regex = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
            let range = NSRange(user.startIndex..., in: user)
            let count = regex.matches(in: user, range: range).count
            var pairs: [String] = []
            for i in 0..<count {
                pairs.append("\"\(i)\": \"\(prefix) \(i)\"")
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }

    // MARK: - Empty input

    func testEmptyInputProducesEmptyReportAndNoLLMCalls() async throws {
        let mock = MockLLMClient([])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport([])
        XCTAssertEqual(result.segments.count, 0)
        XCTAssertEqual(result.report.totalSegments, 0)
        XCTAssertEqual(result.report.batchCount, 0)
        let calls = await mock.calls
        XCTAssertTrue(calls.isEmpty, "Empty input must not call the LLM")
    }

    // MARK: - No rules enabled

    func testNoRulesEnabledThrows() async {
        UserDefaults.standard.set(false, forKey: "polishRemoveFiller")
        UserDefaults.standard.set(false, forKey: "polishFixPunctuation")
        UserDefaults.standard.set(false, forKey: "polishFixGrammar")

        let mock = MockLLMClient([])
        let pass = CleanupPass(client: mock, model: "test/model")
        do {
            _ = try await pass.cleanWithReport(makeSegments(["hello"]))
            XCTFail("Expected noRulesEnabled to throw")
        } catch CleanupPass.CleanError.noRulesEnabled {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testForceAllRulesIfEmptyOverridesUserDefaults() async throws {
        UserDefaults.standard.set(false, forKey: "polishRemoveFiller")
        UserDefaults.standard.set(false, forKey: "polishFixPunctuation")
        UserDefaults.standard.set(false, forKey: "polishFixGrammar")

        let mock = MockLLMClient([jsonObjectEcho("clean")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(
            makeSegments(["um hello", "uh world"]),
            forceAllRulesIfEmpty: true
        )
        XCTAssertEqual(result.report.rulesEnabled.count, 3,
                       "force-all should enable filler+punct+grammar")
        XCTAssertEqual(result.segments.count, 2)
    }

    // MARK: - Artifact pre-filter

    func testArtifactPreFilterBlanksNonSpeechSegments() async throws {
        let segments = makeSegments([
            "[coughing]",
            "Hello there.",
            "[BLANK_AUDIO]",
            "(birds chirping)",
            "<music>",
            "Real spoken line."
        ])
        // The LLM is still called for the whole batch; mock returns echoed
        // text. The pre-filter should override its output for artifact lines.
        let mock = MockLLMClient([jsonObjectEcho("CLEANED")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)

        XCTAssertEqual(result.report.artifactsDropped, 4)
        // Artifact rows must be blanked, not echoed.
        XCTAssertEqual(result.segments[0].cleanedText, "")
        XCTAssertEqual(result.segments[2].cleanedText, "")
        XCTAssertEqual(result.segments[3].cleanedText, "")
        XCTAssertEqual(result.segments[4].cleanedText, "")
        // Non-artifact rows get the LLM's cleaned text.
        XCTAssertEqual(result.segments[1].cleanedText, "CLEANED 1")
        XCTAssertEqual(result.segments[5].cleanedText, "CLEANED 5")
    }

    func testArtifactWithTrailingPunctuationStillDetected() async throws {
        let segments = makeSegments([
            "[silence].",
            "(typing) ",
            "[laughter]!"
        ])
        let mock = MockLLMClient([jsonObjectEcho("X")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        XCTAssertEqual(result.report.artifactsDropped, 3)
        for seg in result.segments {
            XCTAssertEqual(seg.cleanedText, "")
        }
    }

    func testRealTextWithBracketedAsideIsNotArtifact() async throws {
        let segments = makeSegments([
            "Hello [pause] world",   // bracket inside, not whole line
            "Yes [laughter] ok"
        ])
        let mock = MockLLMClient([jsonObjectEcho("CLEANED")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        XCTAssertEqual(result.report.artifactsDropped, 0,
                       "Embedded bracket asides must not be classified as artifacts")
        XCTAssertEqual(result.segments[0].cleanedText, "CLEANED 0")
    }

    // MARK: - Chunking behavior

    func testLongInputChunksInto50PerBatch() async throws {
        // 51 segments → 2 batches (50 + 1).
        let segments = makeSegments((0..<51).map { "line \($0)" })
        let mock = MockLLMClient([jsonObjectEcho("c"), jsonObjectEcho("c")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        XCTAssertEqual(result.report.batchCount, 2)
        XCTAssertEqual(result.segments.count, 51)
        let calls = await mock.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testFiftySegmentsExactlyIsSingleBatch() async throws {
        let segments = makeSegments((0..<50).map { "line \($0)" })
        let mock = MockLLMClient([jsonObjectEcho("c")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        XCTAssertEqual(result.report.batchCount, 1)
        let calls = await mock.calls
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - JSON object parsing (the count-mismatch fix)

    func testJSONObjectMissingIndexFallsBackToOriginal() async throws {
        // LLM returns object with only some keys — missing keys must keep
        // the original text rather than throwing a count-mismatch error.
        let segments = makeSegments(["alpha", "beta", "gamma"])
        let response: @Sendable (String) -> String = { _ in
            // Only return key "1" — keys 0 and 2 should fall back.
            return "{ \"1\": \"BETA-CLEANED\" }"
        }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        XCTAssertEqual(result.segments[0].cleanedText, "alpha")
        XCTAssertEqual(result.segments[1].cleanedText, "BETA-CLEANED")
        XCTAssertEqual(result.segments[2].cleanedText, "gamma")
    }

    func testJSONObjectWithProseAroundItStillParses() async throws {
        // Models sometimes prefix with "Here you go:". The extractor should
        // grab the {…} substring and ignore the surrounding chatter.
        let response: @Sendable (String) -> String = { _ in
            return "Sure, here you go:\n{ \"0\": \"clean a\", \"1\": \"clean b\" }\nLet me know!"
        }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(makeSegments(["a", "b"]))
        XCTAssertEqual(result.segments[0].cleanedText, "clean a")
        XCTAssertEqual(result.segments[1].cleanedText, "clean b")
    }

    func testJSONArrayFallbackAcceptsLegacyFormat() async throws {
        let response: @Sendable (String) -> String = { _ in
            return "[\"X\", \"Y\", \"Z\"]"
        }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(makeSegments(["a", "b", "c"]))
        XCTAssertEqual(result.segments[0].cleanedText, "X")
        XCTAssertEqual(result.segments[1].cleanedText, "Y")
        XCTAssertEqual(result.segments[2].cleanedText, "Z")
    }

    func testJSONArrayShorterThanInputKeepsExtraOriginals() async throws {
        // Array form with fewer entries — leftover positions retain originals
        // instead of throwing the old count-mismatch error.
        let response: @Sendable (String) -> String = { _ in "[\"only-zero\"]" }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(makeSegments(["a", "b", "c"]))
        XCTAssertEqual(result.segments[0].cleanedText, "only-zero")
        XCTAssertEqual(result.segments[1].cleanedText, "b")
        XCTAssertEqual(result.segments[2].cleanedText, "c")
    }

    func testUnparseableResponseThrows() async {
        let response: @Sendable (String) -> String = { _ in "hello, no json here at all" }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        do {
            _ = try await pass.cleanWithReport(makeSegments(["a"]))
            XCTFail("Expected unparseableResponse")
        } catch CleanupPass.CleanError.unparseableResponse {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Report fields

    func testReportCountsModifiedAndUnchangedAndBlanked() async throws {
        let segments = makeSegments(["um hello", "[coughing]", "world", "uh ok"])
        let response: @Sendable (String) -> String = { _ in
            // index 0: modified ("hello"), 1: artifact handled by pre-filter,
            //         2: unchanged ("world"), 3: blanked ("")
            return "{ \"0\": \"hello\", \"1\": \"ignored\", \"2\": \"world\", \"3\": \"\" }"
        }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)

        XCTAssertEqual(result.report.totalSegments, 4)
        XCTAssertEqual(result.report.artifactsDropped, 1)
        XCTAssertEqual(result.report.segmentsModified, 1, "‘um hello’ → ‘hello’")
        XCTAssertEqual(result.report.segmentsUnchanged, 1, "‘world’ unchanged")
        // Both the artifact pre-filter and the LLM-blanked filler row
        // produce empty cleanedText, so the report counts both as blanked.
        XCTAssertEqual(result.report.segmentsBlanked, 2)
    }

    func testReportProviderLabelInferredFromModel() async throws {
        let mock = MockLLMClient([jsonObjectEcho("c")])
        let pass = CleanupPass(client: mock, model: "anthropic/claude-3.5-sonnet")
        let result = try await pass.cleanWithReport(makeSegments(["hi"]))
        // "/" makes it openrouter; without "/" it'd be anthropic.
        XCTAssertEqual(result.report.providerLabel, "openrouter")

        let mock2 = MockLLMClient([jsonObjectEcho("c")])
        let pass2 = CleanupPass(client: mock2, model: "claude-3-5-sonnet-latest")
        let result2 = try await pass2.cleanWithReport(makeSegments(["hi"]))
        XCTAssertEqual(result2.report.providerLabel, "anthropic")
    }

    func testReportRulesEnabledReflectsUserDefaults() async throws {
        UserDefaults.standard.set(true,  forKey: "polishRemoveFiller")
        UserDefaults.standard.set(true,  forKey: "polishFixPunctuation")
        UserDefaults.standard.set(false, forKey: "polishFixGrammar")

        let mock = MockLLMClient([jsonObjectEcho("c")])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(makeSegments(["hi"]))
        XCTAssertEqual(result.report.rulesEnabled.count, 2)
        XCTAssertTrue(result.report.rulesEnabled.contains(where: { $0.contains("filler") }))
        XCTAssertTrue(result.report.rulesEnabled.contains(where: { $0.contains("punctuation") }))
    }

    func testReportWordReductionPercentage() async throws {
        let segments = makeSegments([
            "um hello there my friend",   // 5 words → 3 words after clean
            "uh ok"                         // 2 words → 1 word after clean
        ])
        let response: @Sendable (String) -> String = { _ in
            return "{ \"0\": \"hello there friend\", \"1\": \"ok\" }"
        }
        let mock = MockLLMClient([response])
        let pass = CleanupPass(client: mock, model: "test/model")
        let result = try await pass.cleanWithReport(segments)
        // before: avg (5+2)/2 = 3.5 ; after: avg (3+1)/2 = 2.0
        XCTAssertEqual(result.report.avgWordsBefore, 3.5, accuracy: 0.01)
        XCTAssertEqual(result.report.avgWordsAfter,  2.0, accuracy: 0.01)
        XCTAssertGreaterThan(result.report.wordReductionPct, 0)
    }
}
