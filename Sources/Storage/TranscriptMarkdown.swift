import Foundation

/// Single source of truth for rendering a `TranscriptDocument` to Markdown.
///
/// Both the live-recording pipeline and file imports run through
/// `MeetingPostProcessor`, which renders with `includeSpeakers: true`
/// (channel-tagged recordings show `[Me]`/`[Other]`; untagged imports show
/// nothing). The detail view's manual export keeps `includeSpeakers: false`
/// for backwards-compatible output.
enum TranscriptMarkdown {

    /// Renders `# title` followed by one `**timestamp** [speaker] text` line
    /// per segment. When `includeSpeakers` is false the speaker prefix is
    /// omitted entirely; when true, an unlabelled segment (neither `.me` nor
    /// `.other`) contributes no prefix — so imports render cleanly.
    static func render(_ document: TranscriptDocument,
                       title: String,
                       includeSpeakers: Bool) -> String {
        var out = "# \(title)\n\n"
        for segment in document.segments {
            let stamp = formatTimestamp(segment.start)
            if includeSpeakers {
                let speaker = segment.speaker == .me ? "[Me]"
                    : (segment.speaker == .other ? "[Other]" : "")
                let prefix = speaker.isEmpty ? "" : "\(speaker) "
                out += "**\(stamp)** \(prefix)\(segment.text)\n\n"
            } else {
                out += "**\(stamp)** \(segment.text)\n\n"
            }
        }
        return out
    }

    static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
