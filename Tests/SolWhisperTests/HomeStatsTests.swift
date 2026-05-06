import XCTest
@testable import SolWhisper

final class HomeStatsTests: XCTestCase {

    // MARK: - Helpers

    /// All tests anchor to the same Sunday so weekOfYear filtering is
    /// deterministic regardless of the test machine's clock.
    private let reference: Date = {
        var c = DateComponents()
        c.year = 2026
        c.month = 3
        c.day = 4         // a Wednesday — middle of a week
        c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// Builds a DictationEntry with controllable createdAt + duration.
    /// `polishedText` controls wordCount (one word per token).
    private func entry(daysFromReference: Int,
                       seconds: Double,
                       words: Int,
                       app: String? = "com.example.App") -> DictationEntry {
        let date = calendar.date(byAdding: .day, value: daysFromReference, to: reference)!
        let polished = (0..<max(0, words)).map { "w\($0)" }.joined(separator: " ")
        return DictationEntry(
            createdAt: date,
            durationSeconds: seconds,
            backend: "test",
            originalText: polished,
            polishedText: polished,
            targetAppBundleID: app,
            targetAppName: app == nil ? nil : "App"
        )
    }

    // MARK: - Empty / no entries

    func testEmptyEntriesShowsDashesEverywhere() {
        let stats = HomeStats.compute(from: [], reference: reference, calendar: calendar)
        XCTAssertEqual(stats.wpm, "—")
        XCTAssertEqual(stats.wordsThisWeek, "—")
        XCTAssertEqual(stats.appsUsedThisWeek, "—")
        XCTAssertEqual(stats.savedThisWeek, "—")
    }

    // MARK: - Lifetime WPM

    func testLifetimeWPMComputedFromTotalsNotAverage() {
        // Total: 300 words across 60s + 60s = 120s = 2 min → 150 WPM
        let entries = [
            entry(daysFromReference: 0, seconds: 60, words: 100),
            entry(daysFromReference: 0, seconds: 60, words: 200)
        ]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.wpm, "150")
    }

    func testLifetimeWPMRoundsToInteger() {
        // 50 words / 30 seconds → 100 WPM exactly
        let stats = HomeStats.compute(
            from: [entry(daysFromReference: 0, seconds: 30, words: 50)],
            reference: reference, calendar: calendar
        )
        XCTAssertEqual(stats.wpm, "100")
    }

    func testLifetimeWPMShowsZeroWhenAllDurationsZero() {
        // Entries exist but durations are zero → "0" not "—".
        let entries = [entry(daysFromReference: 0, seconds: 0, words: 10)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.wpm, "0",
                       "Zero-duration entries with words should render as 0, not dash")
    }

    func testNegativeDurationsTreatedAsZero() {
        // Defensive: negative duration shouldn't drive WPM negative.
        let entries = [entry(daysFromReference: 0, seconds: -5, words: 100)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.wpm, "0")
    }

    // MARK: - This week filter

    func testEntriesOutsideWeekDoNotCountForWeeklyTiles() {
        let outside = entry(daysFromReference: -10, seconds: 60, words: 200)
        let stats = HomeStats.compute(from: [outside], reference: reference, calendar: calendar)
        // No entries this week, but entries exist overall → "0", not "—".
        XCTAssertEqual(stats.wordsThisWeek, "0")
        XCTAssertEqual(stats.appsUsedThisWeek, "0")
        XCTAssertEqual(stats.savedThisWeek, "0 s")
    }

    func testEntriesInsideWeekCountForWeeklyTiles() {
        let inside = entry(daysFromReference: 0, seconds: 90, words: 75,
                           app: "com.example.App")
        let stats = HomeStats.compute(from: [inside], reference: reference, calendar: calendar)
        XCTAssertEqual(stats.wordsThisWeek, "75")
        XCTAssertEqual(stats.appsUsedThisWeek, "1")
        // 90 seconds → 1 min (formatter rounds to whole minutes once over 60s)
        XCTAssertEqual(stats.savedThisWeek, "1 min")
    }

    func testWeeklyAppsCountIsUniqueByBundleID() {
        let entries = [
            entry(daysFromReference: 0, seconds: 30, words: 10, app: "com.a"),
            entry(daysFromReference: 0, seconds: 30, words: 10, app: "com.a"),
            entry(daysFromReference: 0, seconds: 30, words: 10, app: "com.b"),
            entry(daysFromReference: 0, seconds: 30, words: 10, app: nil)
        ]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.appsUsedThisWeek, "2",
                       "Distinct bundleIDs only; nil should not be counted")
    }

    // MARK: - Word formatting

    func testThousandsFormattingForLargeWordCounts() {
        let entries = [entry(daysFromReference: 0, seconds: 600, words: 12_345)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        // The exact separator is locale-dependent; just confirm it isn't bare digits
        // and that the underlying number ends in 345.
        XCTAssertTrue(stats.wordsThisWeek.contains("345"))
        XCTAssertNotEqual(stats.wordsThisWeek, "12345",
                          "Should apply NumberFormatter grouping")
    }

    // MARK: - Duration formatting

    func testSavedThisWeekFormatsSecondsForUnderAMinute() {
        let entries = [entry(daysFromReference: 0, seconds: 45, words: 30)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.savedThisWeek, "45 s")
    }

    func testSavedThisWeekFormatsMinutes() {
        // 5 minutes, 0 seconds.
        let entries = [entry(daysFromReference: 0, seconds: 300, words: 100)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.savedThisWeek, "5 min")
    }

    func testSavedThisWeekFormatsHoursAndMinutes() {
        // 1 hour, 30 minutes = 5400 seconds.
        let entries = [entry(daysFromReference: 0, seconds: 5_400, words: 500)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.savedThisWeek, "1h 30m")
    }

    func testSavedThisWeekFormatsExactHours() {
        // 2 hours = 7200 seconds.
        let entries = [entry(daysFromReference: 0, seconds: 7_200, words: 500)]
        let stats = HomeStats.compute(from: entries, reference: reference, calendar: calendar)
        XCTAssertEqual(stats.savedThisWeek, "2 h")
    }
}
