import XCTest
@testable import SolWhisper

final class LanguageDetectorTests: XCTestCase {

    func testDetectsEnglishOnSentence() {
        let result = LanguageDetector.detect("The quick brown fox jumps over the lazy dog.")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.code, "en")
        XCTAssertGreaterThan(result?.confidence ?? 0, LanguageDetector.confidenceThreshold)
    }

    func testDetectsFrenchOnSentence() {
        let result = LanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui ?")
        XCTAssertEqual(result?.code, "fr")
    }

    func testDetectsSimplifiedChinese() {
        let result = LanguageDetector.detect("你好世界,这是一个简单的测试。")
        XCTAssertEqual(result?.code, "zh-Hans")
    }

    func testDetectsTraditionalChinese() {
        let result = LanguageDetector.detect("這是一個繁體中文的測試,你好嗎?")
        XCTAssertEqual(result?.code, "zh-Hant")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(""))
        XCTAssertNil(LanguageDetector.detect("   \n\t  "))
    }

    func testShortAmbiguousInputDoesNotPretendHighConfidence() {
        // "OK" matches several languages — confidence should not exceed the
        // threshold so the UI knows to render an override picker.
        let result = LanguageDetector.detect("OK")
        if let result {
            XCTAssertLessThan(result.confidence, LanguageDetector.confidenceThreshold + 0.05,
                              "Short ambiguous inputs should be marked low-confidence.")
        }
        // nil is also acceptable for very short ambiguous strings.
    }
}
