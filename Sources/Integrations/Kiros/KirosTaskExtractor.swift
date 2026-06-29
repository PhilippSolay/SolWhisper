import Foundation

/// Turns a meeting summary into structured Kiros tasks that belong to the user.
///
/// Depends only on the `LLMClient` protocol, so tests inject a stub returning
/// recorded JSON — no live model calls. The JSON→`[KirosTask]` step is a pure
/// static function (`parse`) so validation is exhaustively testable on its own.
///
/// Everything the model returns is untrusted: `parse` validates and normalizes
/// every field at the boundary (clamps 1–5, whitelists est/energy, checks dates,
/// caps lengths and count) and drops anything that can't be made safe.
struct KirosTaskExtractor {

    let client: LLMClient
    let modelID: String
    /// The system-prompt template. Defaults to the built-in; injectable so a future
    /// Application-Support override can tune extraction without an app rebuild.
    var promptTemplate: String = KirosExtractionPrompt.template

    // Boundary limits (kept in sync with the server contract's MAX_INGEST_TASKS = 50).
    static let maxTasks = 50
    static let maxTitle = 500
    static let maxDescription = 5000
    static let allowedEst: Set<String> = ["30m", "1h", "2h", "4h", "8h"]
    static let allowedEnergy: Set<String> = ["low", "med", "high"]

    /// Extract the user's tasks from `summaryMarkdown`. Returns [] if none apply.
    func extract(summaryMarkdown: String,
                 meetingTitle: String,
                 today: String,
                 identities: [String],
                 fronts: [KirosFront]) async throws -> [KirosTask] {
        let messages = Self.buildMessages(template: promptTemplate,
                                          summaryMarkdown: summaryMarkdown,
                                          meetingTitle: meetingTitle,
                                          today: today,
                                          identities: identities,
                                          fronts: fronts)
        let text = try await client.complete(messages: messages, model: modelID,
                                             temperature: 0.1, maxTokens: 2000)
        return Self.parse(text)
    }

    // MARK: - Pure prompt assembly (testable without an LLM)

    static func buildMessages(template: String,
                              summaryMarkdown: String,
                              meetingTitle: String,
                              today: String,
                              identities: [String],
                              fronts: [KirosFront]) -> [LLMMessage] {
        let who = identities.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let identityText = who.isEmpty ? "the user (me)" : who.joined(separator: " / ")
        let frontsText = fronts.isEmpty
            ? "(none provided — use your best plain-text guess for company/category)"
            : fronts.map { "- \($0.company) · \($0.name) · code \($0.code)" }.joined(separator: "\n")
        let system = MustacheRenderer.render(template, values: [
            "identities": identityText,
            "today": today,
            "fronts": frontsText
        ])
        let user = "Meeting: \(meetingTitle)\n\nSummary:\n\(summaryMarkdown)"
        return [LLMMessage(role: .system, content: system),
                LLMMessage(role: .user, content: user)]
    }

    // MARK: - Pure parse + validate (testable without an LLM)

    /// Parse the model's text into validated tasks. Never throws — malformed
    /// output yields []; individually-bad tasks are dropped, good ones kept.
    static func parse(_ text: String) -> [KirosTask] {
        guard let data = jsonObjectData(in: text),
              let env = try? JSONDecoder().decode(ExtractionEnvelope.self, from: data),
              let raw = env.tasks else { return [] }
        var out: [KirosTask] = []
        for item in raw.prefix(maxTasks) {
            if let task = validate(item, idx: out.count) { out.append(task) }
        }
        return out
    }

    /// Isolate the JSON object from a response that may be fenced or prose-wrapped.
    static func jsonObjectData(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    static func validate(_ raw: ExtractedTask, idx: Int) -> KirosTask? {
        guard let title = clean(raw.title) else { return nil }   // title is required
        return KirosTask(
            idx: idx,
            title: String(title.prefix(maxTitle)),
            company: clean(raw.company),
            category: clean(raw.category),
            project: clean(raw.project),
            front: clean(raw.front),
            importance: inRange(raw.importance),
            urgency: inRange(raw.urgency),
            est: normalizeEst(raw.est),
            due: validDue(raw.due),
            energy: normalizeEnergy(raw.energy),
            avoid: raw.avoid,
            taskDescription: clean(raw.description).map { String($0.prefix(maxDescription)) }
        )
    }

    // MARK: - field normalizers

    private static func clean(_ s: String?) -> String? {
        guard let v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
    private static func inRange(_ n: Int?) -> Int? {
        guard let n, (1...5).contains(n) else { return nil }
        return n
    }
    private static func normalizeEst(_ s: String?) -> String? {
        guard let v = clean(s)?.lowercased() else { return nil }
        return allowedEst.contains(v) ? v : nil
    }
    private static func normalizeEnergy(_ s: String?) -> String? {
        guard var v = clean(s)?.lowercased() else { return nil }
        if v == "medium" { v = "med" }
        return allowedEnergy.contains(v) ? v : nil
    }
    private static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
    private static func validDue(_ s: String?) -> String? {
        guard let v = clean(s), dueFormatter.date(from: v) != nil else { return nil }
        return v
    }
}

/// Decoded shape of the model's JSON. Tolerant: a single bad field doesn't sink
/// the whole task (missing/odd values decode to nil and get fixed in `validate`).
struct ExtractedTask: Decodable {
    let title: String?
    let company: String?
    let category: String?
    let project: String?
    let front: String?
    let importance: Int?
    let urgency: Int?
    let est: String?
    let due: String?
    let energy: String?
    let avoid: Bool?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case title, company, category, project, front
        case importance, urgency, est, due, energy, avoid, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        company = try? c.decodeIfPresent(String.self, forKey: .company)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        project = try? c.decodeIfPresent(String.self, forKey: .project)
        front = try? c.decodeIfPresent(String.self, forKey: .front)
        importance = Self.flexInt(c, .importance)
        urgency = Self.flexInt(c, .urgency)
        est = try? c.decodeIfPresent(String.self, forKey: .est)
        due = try? c.decodeIfPresent(String.self, forKey: .due)
        energy = try? c.decodeIfPresent(String.self, forKey: .energy)
        avoid = try? c.decodeIfPresent(Bool.self, forKey: .avoid)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
    }

    /// Models sometimes return numbers as strings or floats — accept all three.
    private static func flexInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Int(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

private struct ExtractionEnvelope: Decodable {
    let tasks: [ExtractedTask]?
}
