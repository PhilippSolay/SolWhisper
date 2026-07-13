import XCTest
@testable import SolWhisper

/// Stub `LLMClient` so `translate()` can be exercised end-to-end without a live
/// provider — records the messages it received and returns a canned response.
private final class StubTranslationClient: LLMClient, @unchecked Sendable {
    let response: String
    private(set) var received: [LLMMessage] = []
    init(response: String) { self.response = response }
    func complete(messages: [LLMMessage], model: String,
                  temperature: Double, maxTokens: Int) async throws -> String {
        received = messages
        return response
    }
}

/// Tests for `LLMTranslationEngine`. The empty-input path needs no provider; the
/// rest inject a resolved stub client (fix #5) so prompt assembly, postProcess
/// quote-stripping, and the empty-response guard run without UserDefaults /
/// Keychain / a live model.
final class LLMTranslationEngineTests: XCTestCase {

    @MainActor
    func testEmptyInputThrows() async {
        let engine = LLMTranslationEngine()
        do {
            _ = try await engine.translate(text: "   \n  ",
                                           sourceCode: nil,
                                           targetCode: "en")
            XCTFail("Expected .empty to be thrown")
        } catch LLMTranslationEngine.EngineError.empty {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInputCharLimitIsReasonable() {
        // Translation inputs from screen captures are usually under 2k chars,
        // so the 4k cap leaves plenty of headroom while keeping any single
        // call's token spend bounded. This test guards against accidental
        // regressions of the constant.
        XCTAssertGreaterThanOrEqual(LLMTranslationEngine.inputCharLimit, 2_000)
        XCTAssertLessThanOrEqual(LLMTranslationEngine.inputCharLimit, 16_000)
    }

    // MARK: - Injected resolved client (fix #5)

    @MainActor
    private func engine(returning response: String,
                        model: String = "test-model") -> (LLMTranslationEngine, StubTranslationClient) {
        let stub = StubTranslationClient(response: response)
        let engine = LLMTranslationEngine(
            resolvedClient: LLMResolver.Resolved(client: stub, modelID: model, providerLabel: "test"))
        return (engine, stub)
    }

    @MainActor
    func testPostProcessStripsPrefixAndSurroundingQuotes() async throws {
        let (engine, _) = engine(returning: "Translation: \"Bonjour le monde\"")
        let out = try await engine.translate(text: "Hello world", sourceCode: "en", targetCode: "fr")
        XCTAssertEqual(out.translated, "Bonjour le monde",
                       "\"Translation:\" prefix and wrapping quotes must be stripped")
        XCTAssertEqual(out.modelID, "test-model")
    }

    @MainActor
    func testEmptyModelResponseThrowsEmptyResponseGuard() async {
        // Model returned just a pair of quotes → postProcess yields "" → the
        // guard must throw rather than hand the user an empty clipboard.
        let (engine, _) = engine(returning: "\"\"", model: "flaky-model")
        do {
            _ = try await engine.translate(text: "Hello", sourceCode: nil, targetCode: "de")
            XCTFail("Expected .emptyResponse to be thrown")
        } catch LLMTranslationEngine.EngineError.emptyResponse(let model) {
            XCTAssertEqual(model, "flaky-model")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testTranslateSendsSystemPromptWithTargetLanguageAndUserPayload() async throws {
        let (engine, stub) = engine(returning: "Hola")
        _ = try await engine.translate(text: "Hi", sourceCode: nil, targetCode: "es")
        XCTAssertEqual(stub.received.count, 2, "system + user messages")
        XCTAssertEqual(stub.received[0].role, .system)
        XCTAssertTrue(stub.received[0].content.contains("Spanish"),
                      "system prompt must name the target language")
        XCTAssertEqual(stub.received[1].role, .user)
        XCTAssertEqual(stub.received[1].content, "Hi", "user message is the (untruncated) input")
    }
}
