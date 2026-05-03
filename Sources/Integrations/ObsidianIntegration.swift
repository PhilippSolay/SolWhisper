import Foundation

/// Writes a meeting summary as a Markdown note inside an Obsidian vault.
/// No plugins required — Obsidian picks up new files automatically.
///
/// Fields read from UserDefaults:
///   - `obsidianVaultPath`   absolute path to vault root
///   - `obsidianFolder`      subfolder inside vault (default "Calls")
///   - `obsidianFilenameTemplate` mustache (default `{{date}}-{{slug}}.md`)
///   - `obsidianEnabled`     on/off toggle (default false)
///   - `obsidianIncludeAudioLink` link to audio file (default true)
struct ObsidianIntegration {

    static var isConfigured: Bool {
        let path = UserDefaults.standard.string(forKey: "obsidianVaultPath") ?? ""
        return !path.isEmpty
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "obsidianEnabled") && isConfigured
    }

    @discardableResult
    static func write(meeting: Meeting,
                      transcriptMarkdown: String,
                      summaryMarkdown: String,
                      audioFileURL: URL?) throws -> URL? {
        guard let vaultPath = UserDefaults.standard.string(forKey: "obsidianVaultPath"),
              !vaultPath.isEmpty else { return nil }

        let folder = UserDefaults.standard.string(forKey: "obsidianFolder") ?? "Calls"
        let template = UserDefaults.standard.string(forKey: "obsidianFilenameTemplate")
                       ?? "{{date}}-{{slug}}.md"

        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: meeting.createdAt)
        }()
        let slug = MeetingStore.normalizeSlug(meeting.title)
        let filename = MustacheRenderer.render(template, values: [
            "date": dateStr,
            "slug": slug,
            "title": meeting.title
        ])

        let vaultURL = URL(fileURLWithPath: vaultPath, isDirectory: true)
        let folderURL = vaultURL.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let noteURL = folderURL.appendingPathComponent(filename)

        let includeAudio = UserDefaults.standard.object(forKey: "obsidianIncludeAudioLink") as? Bool ?? true
        var body = "# \(meeting.title)\n\n"
        body += "*\(dateStr)* — \(formatDuration(meeting.durationSeconds))\n\n"
        if !summaryMarkdown.isEmpty {
            body += summaryMarkdown
            body += "\n\n---\n\n"
        }
        body += "## Transcript\n\n"
        body += transcriptMarkdown
        if includeAudio, let audioFileURL {
            body += "\n\n---\n\n"
            body += "Audio: [\(audioFileURL.lastPathComponent)](\(audioFileURL.path))\n"
        }

        try body.write(to: noteURL, atomically: true, encoding: .utf8)
        return noteURL
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}
