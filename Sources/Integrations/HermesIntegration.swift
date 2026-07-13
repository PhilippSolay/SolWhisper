import Foundation

/// Pre-baked integration for the user's Hermes VPS. Wraps `OutboundWebhook`
/// with the JSON schema `ingest.py` already accepts.
///
/// Fields read from UserDefaults / Keychain:
///   - `hermesURL`              webhook URL
///   - Keychain `hermesSecret`  HMAC-SHA256 secret
///   - `hermesEnabled`          on/off toggle (default false)
///   - `hermesIncludeTranscript` send transcript markdown (default true)
///   - `hermesIncludeSummary`   send summary markdown (default true)
struct HermesIntegration {

    static var isConfigured: Bool {
        let url = UserDefaults.standard.string(forKey: "hermesURL") ?? ""
        return !url.isEmpty
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "hermesEnabled") && isConfigured
    }

    /// Sends `meeting` to Hermes. Returns the HTTP status (or throws transport errors).
    @discardableResult
    static func send(meeting: Meeting,
                     transcriptMarkdown: String,
                     summaryMarkdown: String) async throws -> Int {
        let urlString = UserDefaults.standard.string(forKey: "hermesURL") ?? ""
        guard isConfigured else { return -1 }
        // Require https (or http to loopback) so a transcript never egresses in
        // cleartext, and a misconfigured http:// URL fails loudly.
        let url = try IntegrationURL.validated(urlString)

        let secret = (try? KeychainStore.string(forKey: "hermesSecret")) ?? nil

        let includeTranscript = UserDefaults.standard.object(forKey: "hermesIncludeTranscript") as? Bool ?? true
        let includeSummary = UserDefaults.standard.object(forKey: "hermesIncludeSummary") as? Bool ?? true

        let payload: [String: Any] = [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "createdAt": ISO8601DateFormatter().string(from: meeting.createdAt),
            "durationSeconds": meeting.durationSeconds,
            "source": meeting.source.rawValue,
            "transcript": includeTranscript ? transcriptMarkdown : "",
            "summary": includeSummary ? summaryMarkdown : ""
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let webhook = OutboundWebhook(url: url, secret: secret)
        return try await webhook.post(body: body)
    }
}
