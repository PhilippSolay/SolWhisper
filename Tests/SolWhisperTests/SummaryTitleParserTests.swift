import XCTest
@testable import SolWhisper

final class SummaryTitleParserTests: XCTestCase {

    // MARK: - Standard pack output

    func testStripsMeetingSummaryEmDashPrefix() {
        let markdown = """
        # Meeting Summary — Sauna & Plunge Pool Project Scope Confirmation

        Some body text follows.
        """
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "Sauna & Plunge Pool Project Scope Confirmation"
        )
    }

    func testStripsMeetingSummaryAsciiDashPrefix() {
        let markdown = "# Meeting Summary - X\n"
        XCTAssertEqual(SummaryTitleParser.extractTitle(from: markdown), "X")
    }

    func testStripsSummaryEmDashPrefix() {
        let markdown = "# Summary — Quarterly Sync\n"
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "Quarterly Sync"
        )
    }

    func testStripsSummaryAsciiDashPrefix() {
        let markdown = "# Summary - Quick Standup\n"
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "Quick Standup"
        )
    }

    // MARK: - Bare H1

    func testReturnsBareH1Title() {
        let markdown = "# Just a title\n"
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "Just a title"
        )
    }

    func testReturnsBareH1WithoutTrailingNewline() {
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: "# Just a title"),
            "Just a title"
        )
    }

    // MARK: - Negative cases

    func testReturnsNilWhenNoH1Present() {
        let markdown = """
        Some intro paragraph.

        - bullet one
        - bullet two
        """
        XCTAssertNil(SummaryTitleParser.extractTitle(from: markdown))
    }

    func testReturnsNilForH2WithoutH1() {
        let markdown = "## A subheading\n\nBody text"
        XCTAssertNil(SummaryTitleParser.extractTitle(from: markdown))
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(SummaryTitleParser.extractTitle(from: ""))
    }

    func testReturnsNilWhenH1TextIsEmptyAfterStripping() {
        // "# Meeting Summary —" with nothing after the em dash collapses to "".
        let markdown = "# Meeting Summary —\n"
        XCTAssertNil(SummaryTitleParser.extractTitle(from: markdown))
    }

    // MARK: - Whitespace handling

    func testHandlesLeadingWhitespaceOnH1Line() {
        let markdown = "   # Indented Title\n"
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "Indented Title"
        )
    }

    func testReturnsFirstH1WhenMultipleH1sPresent() {
        let markdown = """
        # First Title

        # Second Title
        """
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "First Title"
        )
    }

    func testSkipsLeadingNonH1LinesAndFindsH1Below() {
        let markdown = """

        Some preamble line.

        # The Real Title

        Body text.
        """
        XCTAssertEqual(
            SummaryTitleParser.extractTitle(from: markdown),
            "The Real Title"
        )
    }
}
