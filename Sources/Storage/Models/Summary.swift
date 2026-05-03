import Foundation

enum SummarySectionKind: String, Codable, Sendable {
    case overview
    case actionItems
    case decisions
    case openQuestions
    case nextSteps
    case deadlines
    case participants
    case notes
    case custom
}

struct SummarySection: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let heading: String
    let body: String
    let kind: SummarySectionKind

    init(
        id: UUID = UUID(),
        heading: String,
        body: String,
        kind: SummarySectionKind
    ) {
        self.id = id
        self.heading = heading
        self.body = body
        self.kind = kind
    }
}

struct Summary: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var skillId: String
    var llmProvider: String
    var llmModel: String
    var generatedAt: Date
    var sections: [SummarySection]
    var rawMarkdown: String
    /// Resolved meeting type when the summary was produced from a SkillPack
    /// (e.g. `"client-discovery"`). `nil` for legacy flat-skill summaries.
    var meetingType: String?
    /// `"user-set"` if explicitly picked, `"auto-llm"` if the parent skill
    /// classified it in-prompt, `"auto-heuristic"` for keyword-based fallback.
    var classificationSource: String?

    init(
        skillId: String,
        llmProvider: String,
        llmModel: String,
        generatedAt: Date = Date(),
        sections: [SummarySection],
        rawMarkdown: String,
        meetingType: String? = nil,
        classificationSource: String? = nil
    ) {
        self.schemaVersion = SchemaMigration.currentVersion
        self.skillId = skillId
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.generatedAt = generatedAt
        self.sections = sections
        self.rawMarkdown = rawMarkdown
        self.meetingType = meetingType
        self.classificationSource = classificationSource
    }
}
