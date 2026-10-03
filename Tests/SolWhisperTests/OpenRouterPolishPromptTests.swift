import XCTest
@testable import SolWhisper

/// Shape of the dictation-polish system prompt across input languages —
/// asserted without an LLM round-trip.
final class OpenRouterPolishPromptTests: XCTestCase {

    private let keys = ["dictationLanguage", "polishRemoveFiller",
                        "polishFixPunctuation", "polishFixGrammar",
                        "customVocabulary"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testPromptPinsNonEnglishTranscriptLanguage() {
        UserDefaults.standard.set("es-ES", forKey: "dictationLanguage")
        let prompt = OpenRouterClient.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("Spanish (Spain)"),
                      "Prompt must name the selected input language")
        XCTAssertTrue(prompt.contains("NEVER translate"))
    }

    func testPromptHasNoLanguagePinForEnglish() {
        UserDefaults.standard.set("en-US", forKey: "dictationLanguage")
        let prompt = OpenRouterClient.buildSystemPrompt()
        XCTAssertFalse(prompt.contains("NEVER translate"),
                       "English keeps the historical prompt shape")
    }

    func testFillerRuleCoversNonEnglishEquivalents() {
        UserDefaults.standard.set(true, forKey: "polishRemoveFiller")
        UserDefaults.standard.set("fr-FR", forKey: "dictationLanguage")
        let prompt = OpenRouterClient.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("euh"))
        XCTAssertTrue(prompt.contains("transcript's language"))
    }

    func testSpokenPunctuationRuleIsMultilingual() {
        UserDefaults.standard.set("es-MX", forKey: "dictationLanguage")
        let prompt = OpenRouterClient.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("punto"),
                      "Spoken punctuation must cover non-English command words")
    }
}
