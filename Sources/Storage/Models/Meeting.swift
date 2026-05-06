import Foundation

enum MeetingSource: String, Codable, Sendable {
    case recording
    case `import`
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let schemaVersion: Int
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var source: MeetingSource
    var sourceApp: String?
    var participants: [String]
    var transcriptionBackend: String
    var summarySkillId: String?
    var summaryLLMProvider: String?
    var folderName: String
    /// Free-form context the user can add before summarizing — appended to
    /// the summary prompt as "Background you should know about this meeting".
    /// Optional for backwards compat with pre-alpha.4 meetings.
    var context: String?
    /// Maps speaker letter ("A", "B", …) → real name. Populated by the
    /// transcript view's "rename speaker" popover after a diarization pass.
    var speakerNames: [String: String]?
    /// Audit field — which engine produced the speaker labels currently on
    /// the transcript ("assemblyai" / "deepgram" / "fluidaudio" / nil).
    var diarizationEngine: String?
    /// Title of the macOS Calendar event this meeting was linked to (via
    /// the "Link calendar" affordance). Nil = unlinked.
    var calendarEventTitle: String?
    /// `EKEvent.eventIdentifier` of the linked event so we can re-resolve
    /// the canonical attendee list later if needed.
    var calendarEventID: String?

    init(
        id: UUID = UUID(),
        schemaVersion: Int = SchemaMigration.currentVersion,
        title: String = "Untitled",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        durationSeconds: Double = 0,
        source: MeetingSource,
        sourceApp: String? = nil,
        participants: [String] = [],
        transcriptionBackend: String,
        summarySkillId: String? = nil,
        summaryLLMProvider: String? = nil,
        folderName: String,
        context: String? = nil,
        speakerNames: [String: String]? = nil,
        diarizationEngine: String? = nil,
        calendarEventTitle: String? = nil,
        calendarEventID: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.durationSeconds = durationSeconds
        self.source = source
        self.sourceApp = sourceApp
        self.participants = participants
        self.transcriptionBackend = transcriptionBackend
        self.summarySkillId = summarySkillId
        self.summaryLLMProvider = summaryLLMProvider
        self.folderName = folderName
        self.context = context
        self.speakerNames = speakerNames
        self.diarizationEngine = diarizationEngine
        self.calendarEventTitle = calendarEventTitle
        self.calendarEventID = calendarEventID
    }
}
