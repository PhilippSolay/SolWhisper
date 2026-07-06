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

    /// Like `render`, but JSON-escapes every value first so it's safe to drop
    /// inside a `"..."` literal in a JSON template. Without this, a transcript
    /// containing a `"`, `\`, or newline (common in real speech) breaks the
    /// JSON — and a crafted phrase from a meeting participant could inject
    /// sibling keys into the webhook payload. Numbers pass through unchanged.
    static func renderJSON(_ template: String, values: [String: String]) -> String {
        var escaped: [String: String] = [:]
        for (key, value) in values { escaped[key] = jsonEscape(value) }
        return render(template, values: escaped)
    }

    /// Escapes a string for embedding inside a JSON string literal (no
    /// surrounding quotes — the template supplies those).
    static func jsonEscape(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return "" }
        return String(encoded.dropFirst().dropLast())
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
