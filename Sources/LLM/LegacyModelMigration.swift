import Foundation

/// One-shot migration that converts pre-alpha.4 routing state into the
/// `ConfiguredModel`-based world.
///
/// Pre-alpha.4 the routing was a string ("openrouter" / "ollama") + the
/// model id was a separate UserDefault (`openRouterModel`,
/// `summaryOpenRouterModel`, etc.). Alpha.4 introduced `ConfiguredModel`
/// and the routing key now stores its UUID.
///
/// We synthesize ConfiguredModels for any legacy values the user had,
/// then re-point the routing keys at those UUIDs. Idempotent — gated by
/// `modelStoreLegacyMigrationDone` so it runs once.
@MainActor
enum LegacyModelMigration {

    private static let flagKey = "modelStoreLegacyMigrationDone"

    static func migrateIfNeeded(store: ModelStore = .shared) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: flagKey) else { return }
        defer { d.set(true, forKey: flagKey) }

        let legacyDictation = d.string(forKey: "openRouterModel") ?? ""
        let legacySummary   = d.string(forKey: "summaryOpenRouterModel") ?? ""

        // Only synthesize models if there's a real legacy value to migrate.
        // Empty strings = nothing was set; skip.
        let dictationID = ensureModel(modelID: legacyDictation, store: store)
        let summaryID   = ensureModel(modelID: legacySummary,   store: store)

        // Re-point routing keys ONLY when they currently hold legacy
        // string tags. Already-migrated UUIDs stay untouched.
        let legacyRoutingValues: Set<String> = ["openrouter", "ollama", ""]

        if let id = dictationID {
            if let raw = d.string(forKey: "dictationLLMProvider"),
               legacyRoutingValues.contains(raw) {
                d.set(id, forKey: "dictationLLMProvider")
            } else if d.string(forKey: "dictationLLMProvider") == nil {
                d.set(id, forKey: "dictationLLMProvider")
            }
            if let raw = d.string(forKey: "cleanupLLMProvider"),
               legacyRoutingValues.contains(raw) {
                d.set(id, forKey: "cleanupLLMProvider")
            } else if d.string(forKey: "cleanupLLMProvider") == nil {
                d.set(id, forKey: "cleanupLLMProvider")
            }
        }
        if let id = summaryID {
            if let raw = d.string(forKey: "summaryLLMProvider"),
               legacyRoutingValues.contains(raw) {
                d.set(id, forKey: "summaryLLMProvider")
            } else if d.string(forKey: "summaryLLMProvider") == nil {
                d.set(id, forKey: "summaryLLMProvider")
            }
        }

        DebugLog.shared.log(icon: "🛣️", label: "Legacy model migration",
                            value: "dictation=\(legacyDictation.isEmpty ? "—" : legacyDictation) summary=\(legacySummary.isEmpty ? "—" : legacySummary)")
    }

    /// Returns the UUID string for a ConfiguredModel matching the given
    /// `modelID` under the openrouter provider — creating one if missing.
    /// Returns nil if `modelID` is empty.
    private static func ensureModel(modelID: String, store: ModelStore) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let existing = store.models.first(where: {
            $0.provider == .openrouter && $0.modelID == trimmed
        }) {
            return existing.id.uuidString
        }
        let synth = ConfiguredModel(provider: .openrouter, modelID: trimmed)
        store.add(synth)
        return synth.id.uuidString
    }
}
