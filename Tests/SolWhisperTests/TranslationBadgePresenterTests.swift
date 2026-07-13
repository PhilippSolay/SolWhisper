import XCTest
@testable import SolWhisper

/// BUG 1 (privacy blocker): the footer badge must reflect the engine that
/// ACTUALLY produced the result, never the user's setting. When the Apple
/// (on-device) path falls back to a cloud AI model for an Apple-unsupported
/// language, the badge must NOT read "On-device" — it must disclose the egress.
final class TranslationBadgePresenterTests: XCTestCase {

    // MARK: - Badge mapping

    func testOnDeviceResultShowsOnDeviceBadgeWithNoNote() {
        let badge = TranslationBadgePresenter.badge(userEngine: .apple, used: .onDevice)
        XCTAssertEqual(badge.label, "On-device")
        XCTAssertNil(badge.note, "A genuine on-device translation discloses nothing")
    }

    func testAppleFallbackToAIModelIsNeverLabeledOnDevice() {
        // User chose Apple, but the language routed to a cloud model.
        let badge = TranslationBadgePresenter.badge(
            userEngine: .apple, used: .aiModel(provider: "OpenAI"))
        XCTAssertNotEqual(badge.label, "On-device",
                          "Never render On-device on a path that egressed text")
        XCTAssertEqual(badge.label, "Sent to OpenAI")
        XCTAssertNotNil(badge.note, "Must disclose why an on-device request egressed")
    }

    func testAppleFallbackWithUnknownProviderStillNotOnDevice() {
        let badge = TranslationBadgePresenter.badge(
            userEngine: .apple, used: .aiModel(provider: nil))
        XCTAssertNotEqual(badge.label, "On-device")
        XCTAssertEqual(badge.label, "Sent to AI model")
        XCTAssertNotNil(badge.note)
    }

    func testDeliberateLLMEngineShowsAIModelNotLLM() {
        let badge = TranslationBadgePresenter.badge(
            userEngine: .llm, used: .aiModel(provider: "Anthropic"))
        XCTAssertEqual(badge.label, "AI model", "Copy convention renames LLM → AI model")
        XCTAssertNil(badge.note, "User deliberately chose the AI engine — no fallback note")
    }

    // MARK: - Engine-used construction

    func testProviderLabelMapsToDisplayName() {
        XCTAssertEqual(TranslationEngineUsed.fromProviderLabel("openai"),
                       .aiModel(provider: "OpenAI"))
        XCTAssertEqual(TranslationEngineUsed.fromProviderLabel("anthropic"),
                       .aiModel(provider: "Anthropic"))
        XCTAssertEqual(TranslationEngineUsed.fromProviderLabel("openrouter"),
                       .aiModel(provider: "OpenRouter"))
    }

    func testUnknownProviderLabelPassesThroughRatherThanDropping() {
        XCTAssertEqual(TranslationEngineUsed.fromProviderLabel("mystery"),
                       .aiModel(provider: "mystery"))
    }

    func testExpectedEngineTracksUserChoiceBeforeAnyResult() {
        XCTAssertEqual(TranslationEngineUsed.expected(for: .apple), .onDevice)
        XCTAssertEqual(TranslationEngineUsed.expected(for: .llm), .aiModel(provider: nil))
    }
}
