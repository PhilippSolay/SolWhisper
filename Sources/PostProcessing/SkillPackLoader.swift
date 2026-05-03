import Foundation

/// Walks the bundle's `Resources/SkillPacks/` directory and the user's
/// `~/Library/Application Support/SolWhisper/SkillPacks/` directory, loading
/// each subfolder as a `SkillPack`.
enum SkillPackLoader {

    /// Loads built-in packs from the bundle. Each pack is a folder under
    /// `Resources/SkillPacks/`. The folder name becomes the pack's ID.
    static func loadBuiltInPacks() -> [SkillPack] {
        guard let baseURL = builtInPacksRoot() else { return [] }
        return loadPacks(at: baseURL, isBuiltIn: true)
    }

    /// Loads user-installed packs from
    /// `~/Library/Application Support/SolWhisper/SkillPacks/`.
    static func loadUserPacks() -> [SkillPack] {
        let url = userPacksRoot()
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return loadPacks(at: url, isBuiltIn: false)
    }

    /// Public — used by Settings → Skills "Reveal user packs folder" action.
    static var userPacksDirectory: URL { userPacksRoot() }

    // MARK: - Implementation

    /// Bundle resources are flattened by Xcode unless we anchor on a known
    /// file. We probe for any pack's `SKILL.md` and walk up two levels
    /// (`<pack>/SKILL.md` → `<pack>/` → `SkillPacks/`).
    private static func builtInPacksRoot() -> URL? {
        // Probe for the meeting-summary pack's SKILL.md — it's the canonical
        // built-in. Once we find it, every sibling folder is also a pack.
        guard let url = Bundle.main.url(
            forResource: "SKILL", withExtension: "md",
            subdirectory: "SkillPacks/meeting-summary"
        ) else {
            return nil
        }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func userPacksRoot() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("SkillPacks", isDirectory: true)
    }

    private static func loadPacks(at root: URL, isBuiltIn: Bool) -> [SkillPack] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return entries.compactMap { dir -> SkillPack? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return loadOnePack(at: dir, isBuiltIn: isBuiltIn)
        }
    }

    private static func loadOnePack(at dir: URL, isBuiltIn: Bool) -> SkillPack? {
        let id = dir.lastPathComponent
        let skillURL = dir.appendingPathComponent("SKILL.md")
        guard let parent = readModule(at: skillURL) else { return nil }

        // shared/ — preserve canonical load order so the prompt is reproducible.
        let preferredOrder = ["attribution.md", "action-items.md",
                              "decisions.md", "core-output.md"]
        let sharedDir = dir.appendingPathComponent("shared", isDirectory: true)
        var sharedFiles: [SharedSkillModule] = []

        // Add files in canonical order if present.
        for name in preferredOrder {
            let url = sharedDir.appendingPathComponent(name)
            if let module = readModule(at: url) {
                sharedFiles.append(SharedSkillModule(filename: "shared/\(name)", module: module))
            }
        }
        // Pick up any other .md files we don't know about, alphabetically.
        if let extras = try? FileManager.default.contentsOfDirectory(
            at: sharedDir, includingPropertiesForKeys: nil) {
            let extraOrdered = extras
                .filter { $0.pathExtension.lowercased() == "md" }
                .filter { !preferredOrder.contains($0.lastPathComponent) }
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            for url in extraOrdered {
                if let module = readModule(at: url) {
                    sharedFiles.append(SharedSkillModule(filename: "shared/\(url.lastPathComponent)",
                                                         module: module))
                }
            }
        }

        // types/ — keyed by basename without extension.
        var types: [String: SkillModule] = [:]
        let typesDir = dir.appendingPathComponent("types", isDirectory: true)
        if let typeURLs = try? FileManager.default.contentsOfDirectory(
            at: typesDir, includingPropertiesForKeys: nil) {
            for url in typeURLs where url.pathExtension.lowercased() == "md" {
                let key = url.deletingPathExtension().lastPathComponent
                if let module = readModule(at: url) {
                    types[key] = module
                }
            }
        }

        return SkillPack(
            id: id,
            parent: parent,
            shared: sharedFiles,
            types: types,
            isBuiltIn: isBuiltIn
        )
    }

    private static func readModule(at url: URL) -> SkillModule? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return SkillPack.parseModule(text)
    }
}
