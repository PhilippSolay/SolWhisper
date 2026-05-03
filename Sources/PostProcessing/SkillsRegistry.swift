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

    init() {
        try? FileManager.default.createDirectory(at: Self.userSkillsDirectory,
                                                 withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        var loaded: [Skill] = []
        loaded.append(contentsOf: loadBuiltIns())
        loaded.append(contentsOf: loadUserSkills())
        skills = loaded

        var packs: [SkillPack] = []
        packs.append(contentsOf: SkillPackLoader.loadBuiltInPacks())
        packs.append(contentsOf: SkillPackLoader.loadUserPacks())
        skillPacks = packs
    }

    func skill(withID id: String) -> Skill? {
        skills.first(where: { $0.id == id })
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

    private func loadBuiltIns() -> [Skill] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: "Skills") else {
            return []
        }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Skill.self, from: data)
        }
    }

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
