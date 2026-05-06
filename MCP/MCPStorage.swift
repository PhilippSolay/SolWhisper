import Foundation

/// Reads SolWhisper's on-disk state from
/// `~/Library/Application Support/SolWhisper/`. Each meeting is its own
/// folder containing `meeting.json`, `transcript.json`, `transcript.md`,
/// and optional `summary.md` / `summary.json`.
///
/// We re-decode minimal shapes here rather than depend on the main app's
/// model files — keeps the binary independent and tiny. If the schema
/// drifts we'll just see decode errors.
final class MCPStorage {

    struct Meeting: Codable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date?
        var durationSeconds: Double
        var source: String?
        var participants: [String]?
        var folderName: String
        var summarySkillId: String?
        var context: String?
        var speakerNames: [String: String]?
    }

    struct TranscriptSegment: Codable {
        let start: Double
        let end: Double
        let text: String
        var cleanedText: String?
        var speakerID: String?
    }

    struct TranscriptDocument: Codable {
        let segments: [TranscriptSegment]
    }

    struct DictationEntry: Codable {
        let id: UUID
        let createdAt: Date
        let durationSeconds: Double
        let backend: String
        let originalText: String
        let polishedText: String
        let targetAppName: String?
        let wordCount: Int
    }

    let meetingsRoot: URL
    let historyRoot: URL
    let skillsRoot: URL
    let skillPacksRoot: URL

    init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )) ?? FileManager.default.temporaryDirectory
        let root = support.appendingPathComponent("SolWhisper", isDirectory: true)
        self.meetingsRoot = root.appendingPathComponent("Meetings", isDirectory: true)
        self.historyRoot = root.appendingPathComponent("History", isDirectory: true)
        self.skillsRoot = root.appendingPathComponent("Skills", isDirectory: true)
        self.skillPacksRoot = root.appendingPathComponent("SkillPacks", isDirectory: true)
    }

    // MARK: - Meeting reads

    func listMeetings(query: String?, since: Date?, limit: Int) -> [Meeting] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot, includingPropertiesForKeys: nil)) ?? []
        let decoder = isoDecoder()
        var meetings: [Meeting] = dirs.compactMap { dir in
            let metaURL = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: metaURL),
                  var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
            // Folder name not always stored explicitly — fall back to dir name.
            if m.folderName.isEmpty { m.folderName = dir.lastPathComponent }
            return m
        }
        if let since {
            meetings = meetings.filter { $0.createdAt >= since }
        }
        if let q = query?.lowercased(), !q.isEmpty {
            meetings = meetings.filter { $0.title.lowercased().contains(q) }
        }
        meetings.sort { $0.createdAt > $1.createdAt }
        return Array(meetings.prefix(limit))
    }

    func loadMeeting(id: UUID) -> Meeting? {
        listMeetings(query: nil, since: nil, limit: Int.max).first(where: { $0.id == id })
    }

    func loadTranscript(folderName: String) -> TranscriptDocument? {
        let url = meetingsRoot.appendingPathComponent(folderName)
                              .appendingPathComponent("transcript.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? isoDecoder().decode(TranscriptDocument.self, from: data)
    }

    func loadTranscriptMarkdown(folderName: String) -> String? {
        let url = meetingsRoot.appendingPathComponent(folderName)
                              .appendingPathComponent("transcript.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadSummaryMarkdown(folderName: String) -> String? {
        let url = meetingsRoot.appendingPathComponent(folderName)
                              .appendingPathComponent("summary.md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Search

    /// Cheap substring search across all transcript MDs. Returns
    /// (meetingId, snippet) per hit, capped by `limit`.
    func searchTranscripts(query: String, limit: Int) -> [(meetingID: UUID, title: String, snippet: String)] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [(meetingID: UUID, title: String, snippet: String)] = []
        for m in listMeetings(query: nil, since: nil, limit: 1_000) {
            guard hits.count < limit else { break }
            guard let md = loadTranscriptMarkdown(folderName: m.folderName) else { continue }
            let lower = md.lowercased()
            if let range = lower.range(of: q) {
                let lo = md.index(range.lowerBound, offsetBy: -80, limitedBy: md.startIndex) ?? md.startIndex
                let hi = md.index(range.upperBound, offsetBy: 80, limitedBy: md.endIndex) ?? md.endIndex
                let snippet = String(md[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
                hits.append((meetingID: m.id, title: m.title, snippet: "…\(snippet)…"))
            }
        }
        return hits
    }

    // MARK: - Dictation history

    func listDictationHistory(query: String?, since: Date?, limit: Int) -> [DictationEntry] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: historyRoot, includingPropertiesForKeys: nil)) ?? []
        let decoder = isoDecoder()
        var rows: [DictationEntry] = entries.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let row = try? decoder.decode(DictationEntry.self, from: data) else {
                return nil
            }
            return row
        }
        if let since {
            rows = rows.filter { $0.createdAt >= since }
        }
        if let q = query?.lowercased(), !q.isEmpty {
            rows = rows.filter {
                $0.polishedText.lowercased().contains(q) ||
                $0.originalText.lowercased().contains(q)
            }
        }
        rows.sort { $0.createdAt > $1.createdAt }
        return Array(rows.prefix(limit))
    }

    // MARK: - Skills

    func listFlatSkills() -> [[String: Any]] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: skillsRoot, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return [
                "id": json["id"] ?? "",
                "name": json["name"] ?? "",
                "description": json["description"] ?? "",
                "kind": "flat"
            ]
        }
    }

    func listSkillPackTypes() -> [[String: Any]] {
        let packs = (try? FileManager.default.contentsOfDirectory(
            at: skillPacksRoot, includingPropertiesForKeys: nil)) ?? []
        var out: [[String: Any]] = []
        for packDir in packs {
            let typesDir = packDir.appendingPathComponent("types", isDirectory: true)
            let typeFiles = (try? FileManager.default.contentsOfDirectory(
                at: typesDir, includingPropertiesForKeys: nil)) ?? []
            for f in typeFiles where f.pathExtension.lowercased() == "md" {
                out.append([
                    "id": f.deletingPathExtension().lastPathComponent,
                    "name": prettify(f.deletingPathExtension().lastPathComponent),
                    "kind": "pack-type",
                    "pack": packDir.lastPathComponent
                ])
            }
        }
        return out
    }

    private func prettify(_ id: String) -> String {
        id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
          .joined(separator: " ")
    }

    // MARK: - Resources

    /// Resource URIs:
    ///   solwhisper://meeting/{id}/transcript.md
    ///   solwhisper://meeting/{id}/summary.md
    ///   solwhisper://meeting/{id}/meta.json
    func listResources() -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in listMeetings(query: nil, since: nil, limit: 100) {
            out.append(["uri": "solwhisper://meeting/\(m.id.uuidString)/transcript.md",
                        "name": "\(m.title) — transcript",
                        "mimeType": "text/markdown"])
            out.append(["uri": "solwhisper://meeting/\(m.id.uuidString)/summary.md",
                        "name": "\(m.title) — summary",
                        "mimeType": "text/markdown"])
            out.append(["uri": "solwhisper://meeting/\(m.id.uuidString)/meta.json",
                        "name": "\(m.title) — metadata",
                        "mimeType": "application/json"])
        }
        return out
    }

    func readResource(uri: String) throws -> [[String: Any]] {
        let parts = uri.replacingOccurrences(of: "solwhisper://meeting/", with: "")
            .components(separatedBy: "/")
        guard parts.count == 2,
              let id = UUID(uuidString: parts[0]),
              let meeting = loadMeeting(id: id) else {
            throw NSError(domain: "MCP", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Resource not found: \(uri)"])
        }
        let kind = parts[1]
        switch kind {
        case "transcript.md":
            let text = loadTranscriptMarkdown(folderName: meeting.folderName) ?? ""
            return [["uri": uri, "mimeType": "text/markdown", "text": text]]
        case "summary.md":
            let text = loadSummaryMarkdown(folderName: meeting.folderName) ?? ""
            return [["uri": uri, "mimeType": "text/markdown", "text": text]]
        case "meta.json":
            let dict: [String: Any] = [
                "id": meeting.id.uuidString,
                "title": meeting.title,
                "createdAt": ISO8601DateFormatter().string(from: meeting.createdAt),
                "durationSeconds": meeting.durationSeconds,
                "source": meeting.source ?? "",
                "context": meeting.context ?? "",
                "speakerNames": meeting.speakerNames ?? [:]
            ]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            return [["uri": uri, "mimeType": "application/json",
                     "text": String(data: data, encoding: .utf8) ?? "{}"]]
        default:
            throw NSError(domain: "MCP", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown resource kind: \(kind)"])
        }
    }

    // MARK: - Helpers

    private func isoDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
