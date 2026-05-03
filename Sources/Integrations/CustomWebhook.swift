import Foundation

/// User-defined webhook entry — beyond the built-in Hermes + Obsidian.
/// Persisted as JSON in `~/Library/Application Support/SolWhisper/Webhooks/<id>.json`.
/// HMAC secrets are stored in Keychain, keyed by the webhook ID.
struct CustomWebhook: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var urlString: String
    var enabled: Bool
    var headers: [String: String]
    /// Mustache-style payload template with `{{title}}`, `{{summary_markdown}}`,
    /// `{{transcript_markdown}}`, etc. — see `MustacheRenderer.values(for:…)`.
    var payloadTemplate: String
    /// Mostly informational — always JSON for v0.4.
    var contentType: String

    init(id: UUID = UUID(),
         name: String,
         urlString: String = "",
         enabled: Bool = false,
         headers: [String: String] = [:],
         payloadTemplate: String = Self.defaultTemplate,
         contentType: String = "application/json") {
        self.id = id
        self.name = name
        self.urlString = urlString
        self.enabled = enabled
        self.headers = headers
        self.payloadTemplate = payloadTemplate
        self.contentType = contentType
    }

    static let defaultTemplate = """
    {
      "title": "{{title}}",
      "date": "{{date}}",
      "duration_seconds": {{duration_seconds}},
      "summary": "{{summary_markdown}}",
      "transcript": "{{transcript_markdown}}"
    }
    """

    /// Keychain key for the HMAC secret. Empty string if no secret.
    var keychainKey: String { "customWebhook.\(id.uuidString).secret" }
}

@MainActor
final class CustomWebhookStore: ObservableObject {

    @Published private(set) var webhooks: [CustomWebhook] = []

    let rootDirectory: URL

    static let shared = CustomWebhookStore()

    init(rootDirectory: URL = CustomWebhookStore.defaultRoot) {
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
            .appendingPathComponent("Webhooks", isDirectory: true)
    }

    func add(_ webhook: CustomWebhook) {
        webhooks.append(webhook)
        try? write(webhook)
    }

    func update(_ webhook: CustomWebhook) {
        guard let idx = webhooks.firstIndex(where: { $0.id == webhook.id }) else { return }
        webhooks[idx] = webhook
        try? write(webhook)
    }

    func delete(_ webhook: CustomWebhook) {
        webhooks.removeAll(where: { $0.id == webhook.id })
        let url = rootDirectory.appendingPathComponent("\(webhook.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        try? KeychainStore.delete(key: webhook.keychainKey)
    }

    /// All enabled webhooks — used by the post-stop fan-out.
    var enabled: [CustomWebhook] { webhooks.filter(\.enabled) }

    private func loadAll() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> CustomWebhook? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CustomWebhook.self, from: data)
            }
            .sorted(by: { $0.name < $1.name })
        self.webhooks = entries
    }

    private func write(_ webhook: CustomWebhook) throws {
        let url = rootDirectory.appendingPathComponent("\(webhook.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(webhook)
        try data.write(to: url, options: .atomic)
    }
}
