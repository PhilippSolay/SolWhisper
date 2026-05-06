import Foundation

/// File-backed store for voice profiles.
/// Files live at `~/Library/Application Support/SolWhisper/Voices/<id>.json`
/// (one JSON per profile, mirrors `MeetingStore` / `DictationHistoryStore`
/// shapes for consistency).
@MainActor
final class VoiceProfileStore: ObservableObject {

    @Published private(set) var profiles: [VoiceProfile] = []

    let rootDirectory: URL

    static let shared = VoiceProfileStore()

    init(rootDirectory: URL = VoiceProfileStore.defaultRoot) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory,
                                                  withIntermediateDirectories: true)
        try? loadAll()
    }

    nonisolated static var defaultRoot: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("Voices", isDirectory: true)
    }

    func add(_ profile: VoiceProfile) {
        profiles.append(profile)
        try? write(profile)
    }

    func update(_ profile: VoiceProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.updatedAt = Date()
        profiles[idx] = updated
        try? write(updated)
    }

    func delete(_ profile: VoiceProfile) {
        profiles.removeAll { $0.id == profile.id }
        let url = rootDirectory.appendingPathComponent("\(profile.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Quick name lookup — used by the rename popover's autocomplete.
    var allNames: [String] {
        profiles.map(\.name).sorted()
    }

    // MARK: - IO

    private func loadAll() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> VoiceProfile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                return try? d.decode(VoiceProfile.self, from: data)
            }
            .sorted(by: { $0.name.lowercased() < $1.name.lowercased() })
        self.profiles = entries
    }

    private func write(_ profile: VoiceProfile) throws {
        let url = rootDirectory.appendingPathComponent("\(profile.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }
}
