import XCTest
@testable import SolWhisper

final class OCRPostProcessorTests: XCTestCase {

    // Helper: Vision uses Cartesian coordinates with origin at lower-left.
    // `top` is the topmost Y (maxY); height defaults to 0.04 (≈1 line).
    private func line(_ text: String, top: CGFloat, height: CGFloat = 0.04) -> LineObservation {
        LineObservation(
            text: text,
            confidence: 1,
            boundingBox: CGRect(x: 0, y: top - height, width: 1, height: height)
        )
    }

    func testEmptyInputReturnsEmptyString() {
        XCTAssertEqual(OCRPostProcessor.process([], mode: .keep), "")
        XCTAssertEqual(OCRPostProcessor.process([], mode: .remove), "")
    }

    func testKeepModeJoinsWithNewlinesTopToBottom() {
        let observations = [
            line("first",  top: 0.95),
            line("second", top: 0.90),
            line("third",  top: 0.85)
        ]
        let out = OCRPostProcessor.process(observations, mode: .keep)
        XCTAssertEqual(out, "first\nsecond\nthird")
    }

    func testKeepModeSortsUnsortedInputTopToBottom() {
        let scrambled = [
            line("third",  top: 0.85),
            line("first",  top: 0.95),
            line("second", top: 0.90)
        ]
        let out = OCRPostProcessor.process(scrambled, mode: .keep)
        XCTAssertEqual(out, "first\nsecond\nthird",
                       "Output must be ordered by descending Y regardless of input order")
    }

    func testRemoveModeJoinsCloseLinesIntoOneParagraph() {
        // Three close lines (small gaps) — should collapse to one paragraph.
        let observations = [
            line("one wrapped",       top: 0.95),
            line("sentence across",   top: 0.90),
            line("three lines",       top: 0.85)
        ]
        let out = OCRPostProcessor.process(observations, mode: .remove)
        XCTAssertEqual(out, "one wrapped sentence across three lines")
    }

    func testRemoveModePreservesParagraphsAcrossLargeGaps() {
        // Two paragraphs separated by a large vertical gap (1.6×+ line height).
        let observations = [
            line("paragraph one a", top: 0.95),
            line("paragraph one b", top: 0.90),
            // Gap from 0.86 down to 0.70 = 0.16 ≈ 4× line height → break.
            line("paragraph two a", top: 0.70),
            line("paragraph two b", top: 0.65)
        ]
        let out = OCRPostProcessor.process(observations, mode: .remove)
        XCTAssertEqual(out, "paragraph one a paragraph one b\n\nparagraph two a paragraph two b")
    }

    func testRemoveModeCollapsesMultipleSpaces() {
        let observations = [
            line("hello   world",      top: 0.95),
            line("with  extra  spaces", top: 0.90)
        ]
        let out = OCRPostProcessor.process(observations, mode: .remove)
        XCTAssertEqual(out, "hello world with extra spaces")
    }

    func testRemoveModeSingleLineUnchanged() {
        let out = OCRPostProcessor.process([line("just one", top: 0.5)], mode: .remove)
        XCTAssertEqual(out, "just one")
    }

    func testKeepModeTrimsLeadingTrailingWhitespace() {
        let observations = [
            line("  leading",       top: 0.95),
            line("trailing  ",      top: 0.90)
        ]
        let out = OCRPostProcessor.process(observations, mode: .keep)
        XCTAssertTrue(out.hasPrefix("  leading") || out.hasPrefix("leading"),
                      "Internal spacing in keep mode is preserved verbatim")
        XCTAssertFalse(out.hasSuffix(" "),
                       "Trailing whitespace must be trimmed")
    }
}
