import XCTest
@testable import SolWhisper

/// Regression coverage for the wrong-app paste bug (confidentiality): the
/// keystroke-based paste methods (osascript / AppleScript / AX) fire Cmd-V into
/// whatever app is frontmost, not the stored target. `shouldAbortPaste` is the
/// pure decision that guards against pasting dictated text into the wrong app
/// once focus is lost after activation.
final class PasteManagerTests: XCTestCase {

    private let targetPID: pid_t = 1234

    func testAbortsWhenFrontmostAppDiffersFromTarget() {
        // Focus was stolen: a different pid is frontmost → must abort to clipboard.
        XCTAssertTrue(
            PasteManager.shouldAbortPaste(frontmostPID: 4321, targetPID: targetPID),
            "Different frontmost pid must abort so Cmd-V can't fire into the wrong app"
        )
    }

    func testDoesNotAbortWhenTargetIsStillFrontmost() {
        // Target kept focus → safe to keystroke Cmd-V; preserve existing behavior.
        XCTAssertFalse(
            PasteManager.shouldAbortPaste(frontmostPID: targetPID, targetPID: targetPID),
            "Matching frontmost pid must proceed with the normal paste methods"
        )
    }

    func testAbortsWhenThereIsNoFrontmostApp() {
        // No frontmost app (nil) — we can't confirm the target has focus → abort.
        XCTAssertTrue(
            PasteManager.shouldAbortPaste(frontmostPID: nil, targetPID: targetPID),
            "A nil frontmost pid is not the target, so it must abort to clipboard"
        )
    }
}
