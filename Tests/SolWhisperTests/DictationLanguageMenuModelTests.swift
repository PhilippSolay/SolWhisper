import XCTest
@testable import SolWhisper

/// Tray "Input Language" submenu rules, tested with injected readiness so no
/// filesystem or SFSpeechRecognizer state is involved.
final class DictationLanguageMenuModelTests: XCTestCase {

    private func entries(
        ready: Set<String>,
        selected: String,
        backend: String = "whisperkit"
    ) -> [DictationLanguageMenuModel.Entry] {
        DictationLanguageMenuModel.entries(
            backend: backend,
            selectedID: selected,
            readiness: { lang, _ in ready.contains(lang.id) ? .ready : .needsDownload }
        )
    }

    func testOnlyReadyLanguagesAreListed() {
        let result = entries(ready: ["en-US", "es-ES"], selected: "en-US")
        XCTAssertEqual(result.map(\.id), ["en-US", "es-ES"])
        XCTAssertTrue(result.allSatisfy(\.isReady))
    }

    func testSelectionCarriesTheOnlyCheckmark() {
        let result = entries(ready: ["en-US", "es-ES", "fr-FR"], selected: "es-ES")
        XCTAssertEqual(result.filter(\.isSelected).map(\.id), ["es-ES"])
    }

    func testUnreadySelectionStaysVisibleWithHint() {
        // Pack removed after selection (or backend switched): the active
        // language must not vanish — it shows with the readiness hint.
        let result = entries(ready: ["en-US"], selected: "es-ES")
        XCTAssertEqual(result.map(\.id), ["en-US", "es-ES"])
        let spanish = result.last!
        XCTAssertTrue(spanish.isSelected)
        XCTAssertFalse(spanish.isReady)
        XCTAssertEqual(spanish.title, "Spanish (Spain) (needs download)")
    }

    func testCloudBackendListsWholeCatalog() {
        let result = DictationLanguageMenuModel.entries(
            backend: "deepgram", selectedID: "en-US")
        XCTAssertEqual(result.count, DictationLanguage.curated.count,
                       "Deepgram serves every curated language from the cloud")
    }
}
