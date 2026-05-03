import Foundation

/// One row of the dictation history — a single mode-A press-to-talk session.
/// Persisted as a JSON file at `~/Library/Application Support/SolWhisper/History/<id>.json`.
struct DictationEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: Double
    let backend: String
    let originalText: String
    let polishedText: String
    let targetAppBundleID: String?
    let targetAppName: String?
    let wordCount: Int

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         durationSeconds: Double,
         backend: String,
         originalText: String,
         polishedText: String,
         targetAppBundleID: String?,
         targetAppName: String?) {
        self.id = id
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.backend = backend
        self.originalText = originalText
        self.polishedText = polishedText
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        // Final pasted text drives the word count — that's what the user
        // actually delivered into another app.
        self.wordCount = polishedText.split(whereSeparator: \.isWhitespace).count
    }
}

/// File-based store for dictation history. Mirrors the meeting-store shape:
/// an `ObservableObject` so SwiftUI views auto-refresh, file-backed so
/// reboots / launches don't lose data.
@MainActor
final class DictationHistoryStore: ObservableObject {

    @Published private(set) var entries: [DictationEntry] = []

    let rootDirectory: URL

    static let shared = DictationHistoryStore()

    init(rootDirectory: URL = DictationHistoryStore.defaultRoot) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? loadAll()
    }

    nonisolated static var defaultRoot: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    func record(_ entry: DictationEntry) {
        do {
            let url = rootDirectory.appendingPathComponent("\(entry.id.uuidString).json")
            let data = try jsonEncoder().encode(entry)
            try data.write(to: url, options: .atomic)
            entries.insert(entry, at: 0)   // newest first
        } catch {
            DebugLog.shared.log(icon: "📜", label: "History write failed",
                                value: "\(error)", ok: false)
        }
    }

    func loadAll() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> DictationEntry? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? jsonDecoder().decode(DictationEntry.self, from: data)
            }
        self.entries = entries.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func delete(_ entry: DictationEntry) {
        let url = rootDirectory.appendingPathComponent("\(entry.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        entries.removeAll(where: { $0.id == entry.id })
    }

    private func jsonEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func jsonDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
