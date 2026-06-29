import Foundation

/// Wire models for the Kiros task-ingest contract.
///
/// Source of truth: `Kiros/docs/solwhisper-ingest.md` (frozen). These are faithful
/// DTOs — no validation or business logic lives here (the extractor validates before
/// building them). All immutable value types.

/// One task to file into the Kiros inbox. `idx` + the meeting id form the
/// server-side idempotency key (`url:solwhisper:<meeting_id>:<idx>`), so a resend
/// of the same meeting is deduped server-side.
struct KirosTask: Codable, Equatable, Sendable {
    var idx: Int
    var title: String
    var company: String?      // → front.surface
    var category: String?     // → front.name (Design / Sales / App …)
    var project: String?      // → task.group (client / sub-project)
    var front: String?        // explicit front code; wins server-side if it exists
    var importance: Int?      // 1–5, or nil → server inherits the front default
    var urgency: Int?         // 1–5, or nil
    var est: String?          // effort bucket ("30m","1h","2h","4h","8h"), or nil
    var due: String?          // ISO yyyy-MM-dd, or nil
    var energy: String?       // "low" | "med" | "high", or nil
    var avoid: Bool?
    var taskDescription: String?

    enum CodingKeys: String, CodingKey {
        case idx, title, company, category, project, front
        case importance, urgency, est, due, energy, avoid
        case taskDescription = "description"
    }
}

/// POST /api/ingest/tasks request envelope.
struct KirosIngestRequest: Codable, Equatable, Sendable {
    var source: String
    var meetingId: String
    var meetingTitle: String
    var capturedAt: String      // ISO-8601
    var tasks: [KirosTask]

    enum CodingKeys: String, CodingKey {
        case source
        case meetingId = "meeting_id"
        case meetingTitle = "meeting_title"
        case capturedAt = "captured_at"
        case tasks
    }
}

/// Per-task outcome returned by the ingest endpoint.
struct KirosIngestResult: Codable, Equatable, Sendable {
    var idx: Int
    var status: String          // "created" | "duplicate" | …
    var front: String?
    var url: String?
    var note: String?
}

/// POST /api/ingest/tasks response. Tolerant decode: missing scalars default so a
/// backend that drops a field can't crash the client (never trust external data).
struct KirosIngestResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var created: Int
    var skipped: Int
    var results: [KirosIngestResult]

    init(ok: Bool, created: Int, skipped: Int, results: [KirosIngestResult]) {
        self.ok = ok
        self.created = created
        self.skipped = skipped
        self.results = results
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        results = try c.decodeIfPresent([KirosIngestResult].self, forKey: .results) ?? []
    }
}

/// One front (project) in the user's taxonomy.
struct KirosFront: Codable, Equatable, Sendable {
    var code: String
    var name: String
    var company: String
    var importance: Int
}

/// GET /api/ingest/fronts response.
struct KirosFrontsResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var companies: [String]
    var fronts: [KirosFront]

    init(ok: Bool, companies: [String], fronts: [KirosFront]) {
        self.ok = ok
        self.companies = companies
        self.fronts = fronts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        companies = try c.decodeIfPresent([String].self, forKey: .companies) ?? []
        fronts = try c.decodeIfPresent([KirosFront].self, forKey: .fronts) ?? []
    }
}
