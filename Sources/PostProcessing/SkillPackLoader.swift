import Foundation

/// Walks the bundle's `Resources/SkillPacks/` directory and the user's
/// `~/Library/Application Support/SolWhisper/SkillPacks/` directory, loading
/// each subfolder as a `SkillPack`.
enum SkillPackLoader {

    /// Loads built-in packs **after seeding them into the user folder** so
    /// they show up there as editable copies. Returns nothing on its own
    /// once seeding has run — `loadUserPacks()` is the source of truth.
    /// Kept on the public surface for symmetry with `SkillsRegistry` even
    /// though it now no-ops.
    static func loadBuiltInPacks() -> [SkillPack] {
        seedBuiltInPacksIfMissing()
        return []   // user folder is canonical post-seed
    }

    /// Loads user-installed packs from
    /// `~/Library/Application Support/SolWhisper/SkillPacks/`. After the
    /// first launch this includes the bundled meeting-summary pack as a
    /// fully-editable copy.
    static func loadUserPacks() -> [SkillPack] {
        let url = userPacksRoot()
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return loadPacks(at: url, isBuiltIn: false)
    }

    /// Re-copies any missing pack files from the bundle into the user
    /// folder. Used by the "Restore default pack" button.
    static func restoreMissingBuiltInPacks() {
        seedBuiltInPacksIfMissing(force: false)
    }

    /// Walks bundled packs and copies anything not already in the user
    /// folder. Per-file granularity so a user who deleted ONE module from
    /// a pack gets just that module back, without losing edits to the rest.
    /// `force == true` would overwrite — we never do that automatically.
    private static func seedBuiltInPacksIfMissing(force: Bool = false) {
        guard let bundleRoot = builtInPacksRoot() else { return }
        let userRoot = userPacksRoot()
        try? FileManager.default.createDirectory(
            at: userRoot, withIntermediateDirectories: true)

        guard let packDirs = try? FileManager.default.contentsOfDirectory(
            at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        let fm = FileManager.default
        for srcPack in packDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: srcPack.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let destPack = userRoot.appendingPathComponent(srcPack.lastPathComponent,
                                                            isDirectory: true)
            try? fm.createDirectory(at: destPack, withIntermediateDirectories: true)
            seedFiles(from: srcPack, to: destPack, force: force)
        }
    }

    /// Recursively copies missing files from `src` into `dest`. Skips any
    /// files that already exist on disk (so user edits stay intact).
    private static func seedFiles(from src: URL, to dest: URL, force: Bool) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries {
            let target = dest.appendingPathComponent(entry.lastPathComponent)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                seedFiles(from: entry, to: target, force: force)
            } else {
                if fm.fileExists(atPath: target.path) && !force { continue }
                try? fm.copyItem(at: entry, to: target)
            }
        }
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
