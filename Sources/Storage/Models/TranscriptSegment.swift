import Foundation

enum SpeakerLabel: String, Codable, Sendable {
    case me
    case other
    case unknown
}

struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let confidence: Double?
    let speaker: SpeakerLabel
    var cleanedText: String?

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double? = nil,
        speaker: SpeakerLabel = .unknown,
        cleanedText: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.speaker = speaker
        self.cleanedText = cleanedText
    }
}

struct TranscriptDocument: Codable, Sendable {
    let schemaVersion: Int
    let meetingID: UUID
    var segments: [TranscriptSegment]

    init(meetingID: UUID, segments: [TranscriptSegment]) {
        self.schemaVersion = SchemaMigration.currentVersion
        self.meetingID = meetingID
        self.segments = segments
    }
}
