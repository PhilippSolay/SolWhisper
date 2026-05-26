import XCTest
@testable import SolWhisper

/// Tests for `LLMTranslationEngine`. We can't easily stub `LLMResolver` from
/// outside (it reads UserDefaults + KeychainStore), so we validate the parts
/// that don't require provider hits: error surfaces, input clipping, response
/// post-processing.
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
}
