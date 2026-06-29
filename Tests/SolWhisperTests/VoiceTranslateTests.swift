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

    // MARK: - Controller defaults + passthrough

    @MainActor
    func testControllerDefaultsToAppleEngineAndDefaultTarget() {
        let engineKey = VoiceTranslateController.engineDefaultsKey
        let targetKey = VoiceTranslateController.targetLanguageDefaultsKey
        let prevEngine = UserDefaults.standard.string(forKey: engineKey)
        let prevTarget = UserDefaults.standard.string(forKey: targetKey)
        defer { restore(engineKey, prevEngine); restore(targetKey, prevTarget) }

        UserDefaults.standard.removeObject(forKey: engineKey)
        UserDefaults.standard.removeObject(forKey: targetKey)

        let controller = VoiceTranslateController()
        XCTAssertEqual(controller.engineKind, .apple, "Apple is the v1 default engine")
        XCTAssertEqual(controller.targetCode, TranslationLanguage.defaultTargetCode)
    }

    @MainActor
    func testControllerHonorsStoredEngineSelection() {
        let engineKey = VoiceTranslateController.engineDefaultsKey
        let prevEngine = UserDefaults.standard.string(forKey: engineKey)
        defer { restore(engineKey, prevEngine) }

        UserDefaults.standard.set(TranslationEngineKind.llm.rawValue, forKey: engineKey)
        XCTAssertEqual(VoiceTranslateController().engineKind, .llm)
    }

    @MainActor
    func testEmptyTranscriptPassesThroughWithoutEngine() async throws {
        // Empty / whitespace transcript must never reach an engine (no network,
        // no pack); it returns unchanged.
        let controller = VoiceTranslateController()
        let empty = try await controller.translate("")
        XCTAssertEqual(empty, "")
        let blank = try await controller.translate("   \n  ")
        XCTAssertEqual(blank, "   \n  ", "Whitespace-only input returns unchanged")
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
