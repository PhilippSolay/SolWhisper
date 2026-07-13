import XCTest
@testable import SolWhisper

final class AppleSpeechClientTests: XCTestCase {

    // MARK: - Availability-error classification

    private func assistantError(_ code: Int) -> NSError {
        NSError(domain: "kAFAssistantErrorDomain", code: code)
    }

    func testSiriAndDictationDisabledIsAvailabilityError() {
        // kAFAssistantErrorDomain 1700 — "Siri and Dictation are disabled".
        // The exact failure that ships an actionable message to the user.
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1700)))
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1701)))
    }

    func testMissingOnDeviceAssetIsAvailabilityError() {
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1100)))
        XCTAssertTrue(AppleSpeechClient.isAvailabilityError(assistantError(1101)))
    }

    func testTransientRecognizerErrorsAreNotAvailabilityErrors() {
        // "No speech detected" / retry-class errors must NOT tear down the
        // session with a settings banner.
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(assistantError(203)))
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(assistantError(216)))
    }

    func testCancellationFromOtherDomainIsNotAvailabilityError() {
        // Our own retry path cancels the failed on-device task; the resulting
        // "Recognition request was canceled" must never be treated as fatal.
        let cancel = NSError(domain: "kLSRErrorDomain", code: 301)
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(cancel))
        // Same code in an unrelated domain.
        let unrelated = NSError(domain: NSURLErrorDomain, code: 1700)
        XCTAssertFalse(AppleSpeechClient.isAvailabilityError(unrelated))
    }
}
