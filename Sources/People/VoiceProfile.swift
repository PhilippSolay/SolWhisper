import Foundation

/// One person's voice fingerprint. The embedding is a fixed-dimension
/// float vector produced by a speaker-embedding model (planned: FluidAudio
/// in v0.6). For the scaffold version, profiles can be created with a
/// nil embedding and used purely as a name autocomplete source.
struct VoiceProfile: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Optional source — which meeting + speaker letter this profile was
    /// captured from. Useful for re-extracting embeddings later.
    var sourceMeetingID: UUID?
    var sourceSpeakerLetter: String?
    /// Float-array serialized as Data; nil until v0.6 voice fingerprinting
    /// extracts real embeddings via FluidAudio.
    var embedding: Data?
    var embeddingDim: Int?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         sourceMeetingID: UUID? = nil,
         sourceSpeakerLetter: String? = nil,
         embedding: Data? = nil,
         embeddingDim: Int? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceMeetingID = sourceMeetingID
        self.sourceSpeakerLetter = sourceSpeakerLetter
        self.embedding = embedding
        self.embeddingDim = embeddingDim
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this profile has a real embedding and can participate in
    /// auto-matching. v0.5 scaffold profiles return false; v0.6 once
    /// FluidAudio is wired returns true.
    var hasEmbedding: Bool {
        if let e = embedding, !e.isEmpty, (embeddingDim ?? 0) > 0 { return true }
        return false
    }
}
