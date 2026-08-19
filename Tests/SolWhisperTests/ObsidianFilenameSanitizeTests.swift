import XCTest
@testable import SolWhisper

/// `ObsidianIntegration.sanitizeFilename` -- the guard that stops an
/// attacker-influenceable title (e.g. a calendar-invite event name) from
/// escaping the target vault folder via the filename template.
final class ObsidianFilenameSanitizeTests: XCTestCase {

    func testPlainFilenamePassesThrough() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename("2026-07-13-standup.md"),
                       "2026-07-13-standup.md")
    }

    func testStripsParentTraversal() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename("../../../tmp/pwned.md"),
                       "pwned.md")
    }

    func testStripsEtcPasswdTraversal() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename("../../etc/passwd"),
                       "passwd")
    }

    func testFlattensSubfolder() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename("nested/note.md"),
                       "note.md")
    }

    func testBareDotDotFallsBackToDefault() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename(".."), "untitled.md")
    }

    func testEmptyFallsBackToDefault() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename(""), "untitled.md")
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename("   "), "untitled.md")
    }

    func testStripsLeadingDotHiddenFile() {
        XCTAssertEqual(ObsidianIntegration.sanitizeFilename(".secret.md"), "secret.md")
    }

    func testResultNeverContainsSeparatorsOrParentRefs() {
        for input in ["../a", "a/b/c", "..\\..\\x", "x/../../y", "..", "./.."] {
            let out = ObsidianIntegration.sanitizeFilename(input)
            XCTAssertFalse(out.contains("/"), "'\(input)' -> '\(out)' still has a slash")
            XCTAssertFalse(out.contains("\\"), "'\(input)' -> '\(out)' still has a backslash")
            XCTAssertFalse(out.contains(".."), "'\(input)' -> '\(out)' still has ..")
        }
    }
}
