import XCTest
@testable import SolWhisper

/// Offline, deterministic tests for the voice-translate engine layer +
/// controller. We deliberately do NOT exercise real translation output — the
/// Apple engine needs downloaded language packs and the LLM engine needs the
/// network. Those are covered by the human verification step. Here we test the
/// pure logic: readiness hints, provider-class availability mapping, and the
/// controller's defaults + passthrough behavior.
final class VoiceTranslateTests: XCTestCase {

    // MARK: - Readiness hints

    func testReadinessHintStrings() {
        XCTAssertNil(LanguageReadiness.ready.hint, "Ready languages get no badge")
        XCTAssertEqual(LanguageReadiness.needsDownload.hint, "needs download")
        XCTAssertEqual(LanguageReadiness.unsupported.hint, "not available")
        XCTAssertEqual(LanguageReadiness.modelDependent.hint, "depends on model")
        XCTAssertEqual(LanguageReadiness.llmFallback.hint, "via AI model",
                       "Apple-unsupported languages that auto-route to the LLM engine")
    }

    func testAppleTranslationErrorsAreActionable() {
        let download = AppleTranslationError.needsDownload("German")
        XCTAssertTrue(download.errorDescription?.contains("German") == true)
        XCTAssertTrue(download.errorDescription?.contains("Languages") == true,
                      "Must point at Settings → Languages where the download runs")

        let unsupported = AppleTranslationError.unsupportedLanguage("Farsi")
        XCTAssertTrue(unsupported.errorDescription?.contains("Farsi") == true)
        XCTAssertTrue(unsupported.errorDescription?.contains("Models") == true,
                      "Must point at configuring an AI model as the way out")
    }

    // MARK: - LLM provider-class availability

    @MainActor
    func testLLMReadinessIsModelDependentForLocalOllama() async {
        let key = "translationLLMProvider"
        let previous = UserDefaults.standard.string(forKey: key)
        defer { restore(key, previous) }

        UserDefaults.standard.set("ollama", forKey: key)
        let readiness = await TranslationAvailability.readiness(for: "es", engine: .llm)
        XCTAssertEqual(readiness, .modelDependent,
                       "Local Ollama coverage varies by model — should not be promised as ready")
    }

    @MainActor
    func testLLMReadinessIsReadyForFrontierCloud() async {
        let key = "translationLLMProvider"
        let previous = UserDefaults.standard.string(forKey: key)
        defer { restore(key, previous) }

        UserDefaults.standard.set("openrouter", forKey: key)
        let readiness = await TranslationAvailability.readiness(for: "ja", engine: .llm)
        XCTAssertEqual(readiness, .ready,
                       "Frontier cloud providers cover all curated languages")
    }

    // MARK: - Controller defaults

    @MainActor
    func testControllerDefaultsToDefaultTarget() {
        let targetKey = VoiceTranslateController.targetLanguageDefaultsKey
        let prevTarget = UserDefaults.standard.string(forKey: targetKey)
        defer { restore(targetKey, prevTarget) }

        UserDefaults.standard.removeObject(forKey: targetKey)
        XCTAssertEqual(VoiceTranslateController().targetCode, TranslationLanguage.defaultTargetCode)
    }

    // MARK: - Helpers

    private func restore(_ key: String, _ value: String?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
