import Foundation

/// File-based persistence for meetings. Each meeting lives in its own folder
/// under `~/Library/Application Support/SolWhisper/Meetings/<slug>/`, with
/// canonical metadata in `meeting.json`.
///
/// Owned by `AppDelegate` (NOT a singleton — tests pass a temp directory).
/// The published `meetings` array is sorted newest-first by `createdAt`.
///
/// Schema migration is deferred to `SchemaMigration` — all reads pass through
/// `migrate(rawJSON:)` so future schema bumps don't break loads of old folders.
@MainActor
final class MeetingStore: ObservableObject {

    @Published private(set) var meetings: [Meeting] = []

    let rootDirectory: URL

    init(rootDirectory: URL = MeetingStore.defaultRoot) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Default location

    /// `nonisolated` so it can be used as a default argument from any context,
    /// including non-MainActor call sites and tests.
    ///
    /// User-overridable via `meetingsRootPath` in UserDefaults — set by the
    /// "Move folder…" button in STT Meetings settings. The override takes
    /// effect on next launch (the app captures the root at init time).
    nonisolated static var defaultRoot: URL {
        let override = UserDefaults.standard.string(forKey: "meetingsRootPath") ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Creates a new meeting folder + writes the initial `meeting.json` and
    /// empty `session.log`. The returned model is also appended to `meetings`.
    func create(
        source: MeetingSource,
        title: String? = nil,
        transcriptionBackend: String,
        sourceApp: String? = nil,
        folderSlug: String
    ) throws -> Meeting {
        let folderName = uniqueFolderName(forSlug: folderSlug)
        let folderURL = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let meeting = Meeting(
            title: title ?? "Untitled",
            source: source,
            sourceApp: sourceApp,
            transcriptionBackend: transcriptionBackend,
            folderName: folderName
        )

        try writeMeetingJSON(meeting)
        appendSessionLog(meeting, "Meeting folder created (source: \(source.rawValue))")

        meetings.insert(meeting, at: 0)
        return meeting
    }

    /// Persists changes to `meeting.json`, refreshes the in-memory copy.
    func update(_ meeting: Meeting) throws {
        var updated = meeting
        updated.updatedAt = Date()
        try writeMeetingJSON(updated)

        if let idx = meetings.firstIndex(where: { $0.id == updated.id }) {
            meetings[idx] = updated
        } else {
            meetings.insert(updated, at: 0)
        }
    }

    /// Moves the meeting folder to the system Trash and removes the in-memory copy.
    func delete(_ meeting: Meeting) throws {
        let url = folderURL(for: meeting)
        guard FileManager.default.fileExists(atPath: url.path) else {
            meetings.removeAll { $0.id == meeting.id }
            return
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        meetings.removeAll { $0.id == meeting.id }
    }

    /// Scans the root directory for meeting folders and parses their `meeting.json`.
    /// Idempotent — safe to call repeatedly. Sorted newest-first by `createdAt`.
    func loadAll() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else {
            meetings = []
            return
        }
        let folders = try fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var loaded: [Meeting] = []
        for folder in folders {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let metaURL = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: metaURL) else { continue }
            do {
                let migrated = try SchemaMigration.migrate(rawJSON: data)
                let meeting = try jsonDecoder().decode(Meeting.self, from: migrated)
                loaded.append(meeting)
            } catch {
                appendSessionLog(folderName: folder.lastPathComponent,
                                 "Failed to load meeting.json: \(error)")
                continue
            }
        }

        meetings = loaded.sorted(by: { $0.createdAt > $1.createdAt })
    }

    // MARK: - Transcript / summary I/O

    func writeTranscript(_ document: TranscriptDocument, for meeting: Meeting) throws {
        let url = transcriptJSONURL(for: meeting)
        let data = try jsonEncoder().encode(document)
        try data.write(to: url, options: .atomic)
        appendSessionLog(meeting, "Transcript written (\(document.segments.count) segments)")
    }

    func writeTranscriptMarkdown(_ markdown: String, for meeting: Meeting) throws {
        let url = transcriptMarkdownURL(for: meeting)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    func loadTranscript(for meeting: Meeting) throws -> TranscriptDocument? {
        let url = transcriptJSONURL(for: meeting)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let migrated = try SchemaMigration.migrate(rawJSON: data)
        return try jsonDecoder().decode(TranscriptDocument.self, from: migrated)
    }

    func writeSummary(_ summary: Summary, for meeting: Meeting) throws {
        let url = summaryJSONURL(for: meeting)
        let data = try jsonEncoder().encode(summary)
        try data.write(to: url, options: .atomic)
        try summary.rawMarkdown.write(to: summaryMarkdownURL(for: meeting),
                                       atomically: true, encoding: .utf8)
        appendSessionLog(meeting, "Summary written (skill=\(summary.skillId), model=\(summary.llmModel))")
    }

    func loadSummary(for meeting: Meeting) throws -> Summary? {
        let url = summaryJSONURL(for: meeting)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let migrated = try SchemaMigration.migrate(rawJSON: data)
        return try jsonDecoder().decode(Summary.self, from: migrated)
    }

    // MARK: - Per-meeting session log

    /// Appends a timestamped line to the meeting's `session.log`. Best-effort —
    /// logging must never fail the operation that triggered it.
    func appendSessionLog(_ meeting: Meeting, _ message: String) {
        appendSessionLog(folderName: meeting.folderName, message)
    }

    private func appendSessionLog(folderName: String, _ message: String) {
        let url = rootDirectory
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("session.log")
        let stamp = Self.logTimestampFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: - URL helpers

    func folderURL(for meeting: Meeting) -> URL {
        rootDirectory.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    /// Default audio file URL — extension is appended by callers (`audio.wav`,
    /// `audio.mp3`, …) since imports preserve the original codec.
    func audioURL(for meeting: Meeting, ext: String) -> URL {
        folderURL(for: meeting).appendingPathComponent("audio.\(ext)")
    }

    /// Locates the actual on-disk audio file for the meeting by scanning the
    /// folder for `audio.*`. Returns nil if there is no audio yet (ie. live
    /// recording in progress) or the meeting was deleted on disk.
    func audioFileURL(for meeting: Meeting) -> URL? {
        let folder = folderURL(for: meeting)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        return entries.first(where: { $0.lastPathComponent.hasPrefix("audio.") })
    }

    func transcriptJSONURL(for meeting: Meeting) -> URL {
        folderURL(for: meeting).appendingPathComponent("transcript.json")
    }

    func transcriptMarkdownURL(for meeting: Meeting) -> URL {
        folderURL(for: meeting).appendingPathComponent("transcript.md")
    }

    func summaryJSONURL(for meeting: Meeting) -> URL {
        folderURL(for: meeting).appendingPathComponent("summary.json")
    }

    func summaryMarkdownURL(for meeting: Meeting) -> URL {
        folderURL(for: meeting).appendingPathComponent("summary.md")
    }

    // MARK: - Slug + filename

    /// Builds a folder name in the form `YYYY-MM-DD-<slug>`. If the folder
    /// already exists (slug collision), appends `-HHMM` and then a numeric tail.
    private func uniqueFolderName(forSlug slug: String) -> String {
        let datePrefix = Self.dateFormatter.string(from: Date())
        let cleanSlug = Self.normalizeSlug(slug)
        var candidate = "\(datePrefix)-\(cleanSlug)"

        let fm = FileManager.default
        if !fm.fileExists(atPath: rootDirectory.appendingPathComponent(candidate).path) {
            return candidate
        }

        let timeSuffix = Self.timeFormatter.string(from: Date())
        candidate = "\(datePrefix)-\(cleanSlug)-\(timeSuffix)"
        if !fm.fileExists(atPath: rootDirectory.appendingPathComponent(candidate).path) {
            return candidate
        }

        for n in 2...999 {
            let next = "\(candidate)-\(n)"
            if !fm.fileExists(atPath: rootDirectory.appendingPathComponent(next).path) {
                return next
            }
        }
        return "\(candidate)-\(UUID().uuidString.prefix(6))"
    }

    /// Normalizes a slug: lowercase, strips non-alphanumerics down to hyphens,
    /// collapses runs, trims, truncates to 60 chars. Empty input → "meeting".
    /// `nonisolated` so ObsidianIntegration / generic webhook templates can use
    /// it from non-MainActor contexts.
    nonisolated static func normalizeSlug(_ raw: String) -> String {
        let lower = raw.lowercased()
        let allowed = CharacterSet.alphanumerics
        var pieces = [String]()
        var current = ""
        for scalar in lower.unicodeScalars {
            if allowed.contains(scalar) {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let joined = pieces.joined(separator: "-")
        let trimmed = String(joined.prefix(60))
        return trimmed.isEmpty ? "meeting" : trimmed
    }

    // MARK: - Private encoders / formatters

    private func writeMeetingJSON(_ meeting: Meeting) throws {
        let url = folderURL(for: meeting).appendingPathComponent("meeting.json")
        let data = try jsonEncoder().encode(meeting)
        try data.write(to: url, options: .atomic)
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
