import Foundation

/// Pure value type that derives the four Home tiles from a dictation history.
/// Tested as a unit (no IO, no SwiftUI). Lives next to HomeSettingsView so
/// changes to tile semantics are easy to track.
struct HomeStats {
    var wpm: String
    var wordsThisWeek: String
    var appsUsedThisWeek: String
    var savedThisWeek: String

    static func compute(from entries: [DictationEntry],
                        reference: Date = Date(),
                        calendar: Calendar = .current) -> HomeStats {
        guard !entries.isEmpty else {
            return HomeStats(wpm: "—",
                             wordsThisWeek: "—",
                             appsUsedThisWeek: "—",
                             savedThisWeek: "—")
        }

        // Lifetime WPM. We weight by total words / total seconds, which gives
        // a single rate that's robust to lots of short sessions.
        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        let totalSecs  = entries.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
        let lifetimeWPM: Double = totalSecs > 0
            ? (Double(totalWords) / (totalSecs / 60.0))
            : 0

        // This week's slice — same calendar week as `reference`.
        let thisWeek = entries.filter {
            calendar.isDate($0.createdAt, equalTo: reference, toGranularity: .weekOfYear)
        }
        let weekWords = thisWeek.reduce(0) { $0 + $1.wordCount }
        let weekSecs  = thisWeek.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
        let weekApps  = Set(thisWeek.compactMap { $0.targetAppBundleID }).count

        // When the user has dictation entries on disk but the current calendar
        // week happens to be empty, show "0" rather than "—" so the tile
        // makes it obvious the data is persisted, just absent for this week.
        let hasAnyEntries = !entries.isEmpty
        return HomeStats(
            wpm: lifetimeWPM > 0 ? "\(Int(lifetimeWPM.rounded()))" : (hasAnyEntries ? "0" : "—"),
            wordsThisWeek: weekWords > 0 ? formatThousands(weekWords) : (hasAnyEntries ? "0" : "—"),
            appsUsedThisWeek: weekApps > 0 ? "\(weekApps)" : (hasAnyEntries ? "0" : "—"),
            savedThisWeek: weekSecs > 0 ? formatDuration(weekSecs) : (hasAnyEntries ? "0 s" : "—")
        )
    }

    private static func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let m = total / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h) h" : "\(h)h \(r)m"
    }
}
