import XCTest
@testable import SolWhisper

/// BUG 2 (high): when Apple reports a pair as `.supported` (a pack is missing),
/// the app must queue the ACTUALLY-missing language, not blindly the target.
/// Translating an uninstalled non-English source INTO installed English must
/// queue the SOURCE pack, never English (which deep-links a useless en→en
/// download that can never unblock the translation). Regression from 8b27d13.
final class TranslationPackResolverTests: XCTestCase {

    func testUninstalledNonEnglishSourceIntoEnglishQueuesTheSource() {
        // de (not installed) → en (installed): the regression case.
        let code = TranslationPackResolver.codeToDownload(
            sourceInstalled: false, targetInstalled: true,
            sourceCode: "de", targetCode: "en")
        XCTAssertEqual(code, "de", "The missing SOURCE pack must be queued, not English")
    }

    func testUninstalledTargetQueuesTheTarget() {
        // en (installed) → de (not installed): the normal forward case.
        let code = TranslationPackResolver.codeToDownload(
            sourceInstalled: true, targetInstalled: false,
            sourceCode: "en", targetCode: "de")
        XCTAssertEqual(code, "de")
    }

    func testBothMissingPrefersSourceFirst() {
        let code = TranslationPackResolver.codeToDownload(
            sourceInstalled: false, targetInstalled: false,
            sourceCode: "fr", targetCode: "de")
        XCTAssertEqual(code, "fr", "Source resolved first; the target follows on retry")
    }

    func testBothInstalledFallsBackToSourceDefensively() {
        // `.supported` shouldn't occur when both are installed, but the resolver
        // must still return a sane, non-crashing choice.
        let code = TranslationPackResolver.codeToDownload(
            sourceInstalled: true, targetInstalled: true,
            sourceCode: "es", targetCode: "en")
        XCTAssertEqual(code, "es")
    }
}
