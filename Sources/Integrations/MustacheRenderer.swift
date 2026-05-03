import Foundation

/// Tiny `{{key}}` substitution. Subset of Mustache (no sections, no partials,
/// no escaping rules — values pass through verbatim into JSON / Markdown / etc).
/// Sufficient for the webhook payload templates v0.4 ships. We can swap in a
/// real Mustache library later without breaking call sites.
enum MustacheRenderer {

    /// Renders `template`, replacing `{{key}}` with `values[key]`. Missing
    /// keys are left as the raw `{{key}}` so callers can detect them.
    static func render(_ template: String, values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
            out = out.replacingOccurrences(of: "{{ \(key) }}", with: value)
        }
        return out
    }

    /// Common values built from a meeting + summary. Centralized so every
    /// integration sees the same shape.
    static func values(for meeting: Meeting,
                       transcriptMarkdown: String,
                       summaryMarkdown: String) -> [String: String] {
        let iso = ISO8601DateFormatter().string(from: meeting.createdAt)
        return [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "slug": meeting.folderName,
            "date": iso,
            "duration_seconds": String(Int(meeting.durationSeconds)),
            "source": meeting.source.rawValue,
            "source_app": meeting.sourceApp ?? "",
            "participants": meeting.participants.joined(separator: ", "),
            "transcript_markdown": transcriptMarkdown,
            "summary_markdown": summaryMarkdown
        ]
    }
}
