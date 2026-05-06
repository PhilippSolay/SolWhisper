import Foundation

/// MCP tool definitions + dispatch. Each tool is described with a JSON
/// Schema that MCP clients use for argument validation. Returns are wrapped
/// in MCP's `content[]` shape (an array of `{type: "text", text: "..."}`).
enum MCPTools {

    /// Tool catalog returned by `tools/list`.
    static var all: [[String: Any]] {
        [
            tool(name: "list_meetings",
                 description: "List the user's meetings (newest first). Each row has id, title, date, duration, source, optional summarySkillId.",
                 schema: [
                    "type": "object",
                    "properties": [
                        "since": ["type": "string", "description": "Optional ISO-8601 date; only meetings on/after this date."],
                        "query": ["type": "string", "description": "Optional case-insensitive title substring."],
                        "limit": ["type": "integer", "description": "Max rows (default 50)."]
                    ]
                 ]),
            tool(name: "get_meeting",
                 description: "Returns the full meeting record: title, dates, transcript markdown, summary markdown if present, speakerNames map.",
                 schema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Meeting UUID"]
                    ],
                    "required": ["id"]
                 ]),
            tool(name: "search_transcripts",
                 description: "Substring search across all meeting transcripts. Returns up to `limit` snippets with the meeting id + a context window.",
                 schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search string (case-insensitive substring match)."],
                        "limit": ["type": "integer", "description": "Max hits (default 20)."]
                    ],
                    "required": ["query"]
                 ]),
            tool(name: "list_dictation_history",
                 description: "Recent dictation sessions (mode A press-to-talk). Each row has id, date, duration, words, original + polished text, target app.",
                 schema: [
                    "type": "object",
                    "properties": [
                        "since": ["type": "string", "description": "Optional ISO-8601 date."],
                        "query": ["type": "string", "description": "Optional substring match across original/polished text."],
                        "limit": ["type": "integer", "description": "Max rows (default 50)."]
                    ]
                 ]),
            tool(name: "list_skills",
                 description: "Available summary skills — both flat skills (single prompt template) and meeting-summary skill pack types.",
                 schema: ["type": "object", "properties": [:]])
        ]
    }

    private static func tool(name: String, description: String, schema: [String: Any]) -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "inputSchema": schema
        ]
    }

    /// Dispatches a tool call. Returns MCP's `content[]` payload.
    static func dispatch(name: String, args: [String: Any], storage: MCPStorage) throws -> [[String: Any]] {
        switch name {
        case "list_meetings":
            return [textContent(json: listMeetings(args, storage))]
        case "get_meeting":
            return [textContent(json: try getMeeting(args, storage))]
        case "search_transcripts":
            return [textContent(json: searchTranscripts(args, storage))]
        case "list_dictation_history":
            return [textContent(json: listDictationHistory(args, storage))]
        case "list_skills":
            return [textContent(json: listSkills(storage))]
        default:
            throw NSError(domain: "MCP", code: -32601,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }

    // MARK: - Implementations

    private static func listMeetings(_ args: [String: Any], _ storage: MCPStorage) -> [[String: Any]] {
        let limit = args["limit"] as? Int ?? 50
        let query = args["query"] as? String
        let since = parseISO(args["since"] as? String)
        let rows = storage.listMeetings(query: query, since: since, limit: limit)
        return rows.map { m in
            [
                "id": m.id.uuidString,
                "title": m.title,
                "createdAt": ISO8601DateFormatter().string(from: m.createdAt),
                "durationSeconds": m.durationSeconds,
                "source": m.source ?? "",
                "summarySkillId": m.summarySkillId ?? "",
                "context": m.context ?? ""
            ]
        }
    }

    private static func getMeeting(_ args: [String: Any], _ storage: MCPStorage) throws -> [String: Any] {
        guard let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) else {
            throw NSError(domain: "MCP", code: -32602,
                          userInfo: [NSLocalizedDescriptionKey: "Missing or invalid 'id'"])
        }
        guard let meeting = storage.loadMeeting(id: id) else {
            throw NSError(domain: "MCP", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Meeting not found: \(idStr)"])
        }
        let transcript = storage.loadTranscriptMarkdown(folderName: meeting.folderName) ?? ""
        let summary    = storage.loadSummaryMarkdown(folderName: meeting.folderName) ?? ""
        return [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "createdAt": ISO8601DateFormatter().string(from: meeting.createdAt),
            "durationSeconds": meeting.durationSeconds,
            "source": meeting.source ?? "",
            "context": meeting.context ?? "",
            "speakerNames": meeting.speakerNames ?? [:],
            "transcript": transcript,
            "summary": summary
        ]
    }

    private static func searchTranscripts(_ args: [String: Any], _ storage: MCPStorage) -> [[String: Any]] {
        let query = args["query"] as? String ?? ""
        let limit = args["limit"] as? Int ?? 20
        let hits = storage.searchTranscripts(query: query, limit: limit)
        return hits.map { h in
            [
                "meetingId": h.meetingID.uuidString,
                "title": h.title,
                "snippet": h.snippet
            ]
        }
    }

    private static func listDictationHistory(_ args: [String: Any], _ storage: MCPStorage) -> [[String: Any]] {
        let limit = args["limit"] as? Int ?? 50
        let query = args["query"] as? String
        let since = parseISO(args["since"] as? String)
        let rows = storage.listDictationHistory(query: query, since: since, limit: limit)
        return rows.map { r in
            [
                "id": r.id.uuidString,
                "createdAt": ISO8601DateFormatter().string(from: r.createdAt),
                "durationSeconds": r.durationSeconds,
                "wordCount": r.wordCount,
                "backend": r.backend,
                "originalText": r.originalText,
                "polishedText": r.polishedText,
                "targetAppName": r.targetAppName ?? ""
            ]
        }
    }

    private static func listSkills(_ storage: MCPStorage) -> [String: Any] {
        return [
            "flatSkills": storage.listFlatSkills(),
            "packTypes": storage.listSkillPackTypes()
        ]
    }

    // MARK: - Helpers

    private static func textContent(json value: Any) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return [
            "type": "text",
            "text": String(data: data, encoding: .utf8) ?? "{}"
        ]
    }

    private static func parseISO(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}
