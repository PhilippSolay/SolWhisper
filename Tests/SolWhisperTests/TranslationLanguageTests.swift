import XCTest
@testable import SolWhisper

final class TranslationLanguageTests: XCTestCase {

    func testCuratedListContainsAllAdvertisedLanguages() {
        let codes = TranslationLanguage.curated.map(\.code)
        XCTAssertTrue(codes.contains("en"))
        XCTAssertTrue(codes.contains("fr"))
        XCTAssertTrue(codes.contains("id"))
        XCTAssertTrue(codes.contains("es"))
        XCTAssertTrue(codes.contains("zh-Hans"))
    }

    func testDefaultTargetIsEnglish() {
        XCTAssertEqual(TranslationLanguage.defaultTargetCode, "en")
    }

    func testNamedLookupHitsCuratedEntry() {
        let lang = TranslationLanguage.named("fr")
        XCTAssertEqual(lang.code, "fr")
        XCTAssertEqual(lang.label, "French")
    }

    func testNamedLookupFallsBackToLocale() {
        // Polish isn't in the curated list — should still produce a real
        // localized label (in the current locale), not the raw code.
        let lang = TranslationLanguage.named("pl")
        XCTAssertEqual(lang.code, "pl")
        XCTAssertFalse(lang.label.isEmpty)
        XCTAssertNotEqual(lang.label, "PL", "Fallback should produce a localized name, not just the uppercased code, when Locale has the language.")
    }

    func testSameLanguageCollapsesRegions() {
        XCTAssertTrue(TranslationLanguage.sameLanguage("en", "en-US"))
        XCTAssertTrue(TranslationLanguage.sameLanguage("en-GB", "en-US"))
        XCTAssertTrue(TranslationLanguage.sameLanguage("EN", "en"))
    }

    func testSameLanguageDistinguishesChineseScripts() {
        XCTAssertFalse(TranslationLanguage.sameLanguage("zh-Hans", "zh-Hant"),
                       "Simplified vs Traditional Chinese is a valid translation pair.")
    }

    func testSameLanguageRejectsDifferentLanguages() {
        XCTAssertFalse(TranslationLanguage.sameLanguage("en", "fr"))
        XCTAssertFalse(TranslationLanguage.sameLanguage("id", "es"))
    }
}
