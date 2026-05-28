import Foundation

/// Parses a meeting title out of summary markdown.
///
/// Looks for the first H1 line (`# ...`) in the markdown and returns the
/// text after the `# ` marker. Strips a leading "Meeting Summary —" /
/// "Meeting Summary -" / "Summary —" / "Summary -" prefix when present
/// so the title reads cleanly in lists and integrations.
///
/// Returns `nil` when no H1 line exists, or when the H1 line is empty
/// after the prefix is stripped.
///
/// Lives at file scope (not on `MeetingDetailView`) so it's reachable from
/// unit tests without dragging SwiftUI / MainActor isolation along for the
/// ride.
enum SummaryTitleParser {
    static func extractTitle(from markdown: String) -> String? {
        for line in markdown.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("# ") else { continue }
            var title = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            for prefix in ["Meeting Summary —", "Meeting Summary -",
                           "Summary —", "Summary -"] {
                if title.hasPrefix(prefix) {
                    title = String(title.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            return title.isEmpty ? nil : title
        }
        return nil
    }
}
