import Foundation

/// Loads built-in skills from the bundle and user-defined skills from
/// `~/Library/Application Support/SolWhisper/Skills/`. v0.4 ships read-only
/// built-ins; user skills can be dropped into the folder by hand for now
/// (file-based skill editor lands in Sprint 7+).
@MainActor
final class SkillsRegistry: ObservableObject {

    @Published private(set) var skills: [Skill] = []
    @Published private(set) var skillPacks: [SkillPack] = []

    static let shared = SkillsRegistry()

    /// The canonical meeting-summary pack — convenience accessor used by
    /// the Transcripts UI to populate the type picker without scanning.
    var meetingSummaryPack: SkillPack? {
        skillPacks.first(where: { $0.id == "meeting-summary" })
    }

    static let userSkillsDirectory: URL = {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
    }()

    /// Flat-skill IDs that were retired in alpha.5 in favor of richer
    /// SkillPack types. On first launch after upgrade, any unedited copy
    /// of these in the user folder gets cleaned up so the picker is no
    /// longer cluttered. Edited copies stay (user can prune themselves).
    private static let retiredFlatSkillIDs = [
        "generic", "sales-call", "standup", "one-on-one"
        // brainstorm + interview were lifted into pack types — same fate.
        , "brainstorm", "interview"
    ]

    init() {
        try? FileManager.default.createDirectory(at: Self.userSkillsDirectory,
                                                 withIntermediateDirectories: true)
        retireDecommissionedFlatSkillsOnce()
        seedBuiltInSkillsIfMissing()
        reload()
    }

    /// One-shot: deletes user-folder JSONs whose id matches a retired
    /// built-in. Gated by `retiredFlatSkillsCleanupDone` so users can
    /// re-create one with the same id later without it being wiped.
    private func retireDecommissionedFlatSkillsOnce() {
        guard !UserDefaults.standard.bool(forKey: "retiredFlatSkillsCleanupDone") else {
            return
        }
        defer { UserDefaults.standard.set(true, forKey: "retiredFlatSkillsCleanupDone") }

        for id in Self.retiredFlatSkillIDs {
            let url = Self.userSkillsDirectory.appendingPathComponent("\(id).json")
            try? FileManager.default.removeItem(at: url)
        }
    }

    func reload() {
        // Built-ins ship as seeds in the bundle's `Resources/Skills/`, but
        // they're copied into the user folder on first launch (see
        // `seedBuiltInSkillsIfMissing`) and become regular user skills the
        // user can edit or delete. After seeding the bundle is no longer
        // read at runtime — the user folder is the single source of truth.
        skills = loadUserSkills()

        var packs: [SkillPack] = []
        packs.append(contentsOf: SkillPackLoader.loadBuiltInPacks())
        packs.append(contentsOf: SkillPackLoader.loadUserPacks())
        skillPacks = packs
    }

    /// Copies any bundled skill whose id isn't present in the user folder
    /// into the user folder. Runs every launch so new built-ins shipped in
    /// future app updates get seeded automatically — but never overwrites
    /// existing files (so users keep their edits).
    private func seedBuiltInSkillsIfMissing() {
        guard let bundleURLs = Bundle.main.urls(forResourcesWithExtension: "json",
                                                  subdirectory: "Skills") else {
            return
        }
        for src in bundleURLs {
            let dest = Self.userSkillsDirectory.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    /// Re-copies any missing built-ins from the bundle. Useful when the user
    /// has accidentally deleted one and wants the default back. Doesn't
    /// touch existing files so user edits to other skills stay intact.
    func restoreMissingBuiltIns() {
        seedBuiltInSkillsIfMissing()
        reload()
    }

    func skill(withID id: String) -> Skill? {
        skills.first(where: { $0.id == id })
    }

    // MARK: - User-skill mutation

    /// Writes a user skill to disk and reloads. The id is used as the
    /// filename (`<id>.json`); built-in skills are filtered out by the
    /// loader override that forces `isBuiltIn = false` on user-folder reads,
    /// so a user skill can never overwrite a built-in.
    @discardableResult
    func saveUserSkill(_ skill: Skill) -> Result<Void, Error> {
        var copy = skill
        copy.isBuiltIn = false
        let url = Self.userSkillsDirectory.appendingPathComponent("\(copy.id).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try data.write(to: url, options: .atomic)
            reload()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Removes a user skill from disk + the registry. Built-in skills
    /// can't be deleted (their files live in the bundle, read-only).
    func deleteUserSkill(id: String) {
        let url = Self.userSkillsDirectory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// Validates a candidate id against existing user skills and reserved
    /// built-in ids. Returns nil on success or a human-readable reason.
    func validateUserSkillID(_ id: String, existingID: String?) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "ID is required." }
        // Filename safety: no slashes, no leading dot, no spaces.
        let illegal = CharacterSet(charactersIn: "/\\:")
        if trimmed.rangeOfCharacter(from: illegal) != nil {
            return "ID can't contain / \\ or :"
        }
        // Built-in ids and existing user ids (other than the one we're editing).
        let conflict = skills.first(where: { $0.id == trimmed })
        if let conflict, conflict.id != existingID {
            return "An \(conflict.isBuiltIn ? "built-in" : "existing") skill already uses that ID."
        }
        return nil
    }

    var defaultSkill: Skill {
        skills.first(where: { $0.id == "generic" }) ?? skills.first ?? Skill(
            id: "fallback",
            name: "Fallback",
            description: "Built-in fallback when no skills are loaded",
            promptTemplate: "Summarize this transcript:\n\n{{transcript}}",
            outputTemplate: "",
            defaultLLMProvider: nil,
            defaultLLMModel: nil,
            defaultTemperature: nil,
            isBuiltIn: true
        )
    }

    // MARK: - Loaders

    private func loadUserSkills() -> [Skill] {
        let dir = Self.userSkillsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard var skill = try? JSONDecoder().decode(Skill.self, from: data) else { return nil }
                // Force user skills to be marked as such so the UI knows they're editable.
                skill.isBuiltIn = false
                return skill
            }
    }
}
