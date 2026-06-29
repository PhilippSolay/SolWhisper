import Foundation

enum KirosIntegrationError: Error, Equatable { case noLLM }

/// Files the user's action items into Kiros after a meeting. Mirrors the
/// `HermesIntegration` static-struct shape, but owns the orchestration:
/// resolve an LLM → (best-effort) fetch the front taxonomy → extract the
/// user's tasks → POST them to the ingest contract.
///
/// Settings (UserDefaults): `kirosEnabled`, `kirosURL`, `kirosIdentities`
/// (comma-separated aliases). Bearer token lives in the Keychain.
///
/// `@MainActor` because it calls `LLMResolver` (MainActor) and is invoked from
/// the MainActor-isolated `IntegrationFanout`.
@MainActor
struct KirosIntegration {

    static let enabledKey = "kirosEnabled"
    static let urlKey = "kirosURL"
    static let identitiesKey = "kirosIdentities"
    static let tokenKeychainKey = "kiros.bearerToken"

    static var isConfigured: Bool {
        let url = UserDefaults.standard.string(forKey: urlKey) ?? ""
        let token = (try? KeychainStore.string(forKey: tokenKeychainKey)) ?? nil
        return !url.isEmpty && !(token ?? "").isEmpty
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && isConfigured
    }

    /// Who counts as "me": the display name plus comma-separated aliases,
    /// trimmed, de-duped case-insensitively, order preserved.
    static func identities(displayName: String?, aliases: String?) -> [String] {
        let parts = [displayName ?? ""] + (aliases ?? "").split(separator: ",").map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for raw in parts {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = v.lowercased()
            guard !v.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(v)
        }
        return out
    }

    /// Build the ingest envelope. Pure — the unit under test.
    static func makeRequest(meeting: Meeting, tasks: [KirosTask], capturedAt: Date) -> KirosIngestRequest {
        KirosIngestRequest(
            source: "solwhisper",
            meetingId: meeting.id.uuidString,
            meetingTitle: meeting.title,
            capturedAt: ISO8601DateFormatter().string(from: capturedAt),
            tasks: tasks)
    }

    static func todayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Extract the user's tasks from the summary and file them into Kiros.
    /// Returns 200 on success (including the legit no-op of zero tasks), -1 if
    /// not configured. Throws on LLM / transport failure (the fanout logs it).
    @discardableResult
    static func send(meeting: Meeting,
                     transcriptMarkdown: String,
                     summaryMarkdown: String) async throws -> Int {
        guard isConfigured,
              let url = URL(string: UserDefaults.standard.string(forKey: urlKey) ?? ""),
              let token = ((try? KeychainStore.string(forKey: tokenKeychainKey)) ?? nil),
              !token.isEmpty
        else { return -1 }

        guard let resolved = LLMResolver.resolve(.summary) else {
            throw KirosIntegrationError.noLLM
        }

        let ids = identities(displayName: UserDefaults.standard.string(forKey: "userDisplayName"),
                             aliases: UserDefaults.standard.string(forKey: identitiesKey))
        let client = KirosClient(baseURL: url, token: token)
        // Best-effort taxonomy — a fronts fetch failure must not block filing.
        let fronts = (try? await client.fetchFronts())?.fronts ?? []

        let extractor = KirosTaskExtractor(client: resolved.client, modelID: resolved.modelID)
        let tasks = try await extractor.extract(summaryMarkdown: summaryMarkdown,
                                                meetingTitle: meeting.title,
                                                today: todayString(),
                                                identities: ids,
                                                fronts: fronts)
        guard !tasks.isEmpty else {
            DebugLog.shared.log(icon: "🗂️", label: "Kiros", value: "no tasks for me")
            return 200
        }

        let response = try await client.postTasks(
            makeRequest(meeting: meeting, tasks: tasks, capturedAt: Date()))
        DebugLog.shared.log(icon: "🗂️", label: "Kiros filed",
                            value: "created \(response.created), skipped \(response.skipped)")
        return 200
    }
}
