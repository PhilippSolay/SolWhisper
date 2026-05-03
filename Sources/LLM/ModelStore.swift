import Foundation

// MARK: - Provider catalog

enum ModelProvider: String, CaseIterable, Codable, Sendable {
    case openai     = "openai"
    case anthropic  = "anthropic"
    case google     = "google"
    case groq       = "groq"
    case openrouter = "openrouter"
    case ollama     = "ollama"
    case custom     = "custom"

    var label: String {
        switch self {
        case .openai:     return "OpenAI"
        case .anthropic:  return "Anthropic"
        case .google:     return "Google"
        case .groq:       return "Groq"
        case .openrouter: return "OpenRouter"
        case .ollama:     return "Ollama"
        case .custom:     return "Custom"
        }
    }

    var symbolIcon: String {
        switch self {
        case .openai:     return "circle.hexagongrid"
        case .anthropic:  return "a.circle.fill"
        case .google:     return "g.circle.fill"
        case .groq:       return "9.circle.fill"
        case .openrouter: return "arrow.triangle.branch"
        case .ollama:     return "house"
        case .custom:     return "wand.and.stars"
        }
    }

    var isLocal: Bool { self == .ollama }
    var requiresAPIKey: Bool { self != .ollama && self != .custom }

    /// Where the user gets a key. Surfaced inline in the Add Model sheet.
    var apiKeyURL: URL? {
        switch self {
        case .openai:     return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic:  return URL(string: "https://console.anthropic.com/settings/keys")
        case .google:     return URL(string: "https://aistudio.google.com/apikey")
        case .groq:       return URL(string: "https://console.groq.com/keys")
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .ollama, .custom: return nil
        }
    }

    /// Curated model presets shown in the Add Model sheet's Model picker.
    /// Custom entries can be added via the model dropdown's free-text branch.
    /// Updated for the current (Jan 2026) model generation.
    var presetModelIDs: [String] {
        switch self {
        case .openai:
            return ["gpt-4o", "gpt-4o-mini", "o1", "o1-mini", "o3-mini"]
        case .anthropic:
            return [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest"
            ]
        case .google:
            return [
                "gemini-2.0-flash",
                "gemini-2.0-flash-thinking-exp",
                "gemini-1.5-pro-latest",
                "gemini-1.5-flash-latest"
            ]
        case .groq:
            return [
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "deepseek-r1-distill-llama-70b",
                "mixtral-8x7b-32768"
            ]
        case .openrouter:
            return [
                "anthropic/claude-opus-4-7",
                "anthropic/claude-sonnet-4-6",
                "anthropic/claude-haiku-4-5",
                "anthropic/claude-3-5-sonnet",
                "anthropic/claude-3-5-haiku",
                "openai/gpt-4o",
                "openai/gpt-4o-mini",
                "openai/o1",
                "google/gemini-2.0-flash",
                "google/gemini-1.5-pro"
            ]
        case .ollama:
            return ["llama3.2", "llama3.3", "qwen2.5:14b", "deepseek-r1:14b", "gemma2"]
        case .custom:
            return []
        }
    }

    /// Keychain key for this provider's API key. One key per provider —
    /// shared across all models from that provider.
    var apiKeyKeychainKey: String { "model.provider.\(rawValue).apiKey" }
}

// MARK: - ConfiguredModel

struct ConfiguredModel: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var provider: ModelProvider
    var modelID: String           // e.g. "claude-3-5-sonnet-latest"
    var displayName: String       // user-overridable label, "" → use modelID
    /// Per-row star indicator. v0.5 will use it for "preferred" tagging;
    /// for now it's just visual.
    var isFavorite: Bool

    init(id: UUID = UUID(),
         provider: ModelProvider,
         modelID: String,
         displayName: String = "",
         isFavorite: Bool = false) {
        self.id = id
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName
        self.isFavorite = isFavorite
    }

    /// The string shown in lists. Falls back to the raw model ID.
    var label: String { displayName.isEmpty ? modelID : displayName }
}

// MARK: - ModelStore

@MainActor
final class ModelStore: ObservableObject {

    @Published private(set) var models: [ConfiguredModel] = []

    let rootDirectory: URL

    static let shared = ModelStore()

    init(rootDirectory: URL = ModelStore.defaultRoot) {
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
            .appendingPathComponent("Models", isDirectory: true)
    }

    func add(_ model: ConfiguredModel) {
        models.append(model)
        try? write(model)
    }

    func update(_ model: ConfiguredModel) {
        guard let idx = models.firstIndex(where: { $0.id == model.id }) else { return }
        models[idx] = model
        try? write(model)
    }

    func delete(_ model: ConfiguredModel) {
        models.removeAll(where: { $0.id == model.id })
        let url = rootDirectory.appendingPathComponent("\(model.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        // Note: per-provider API keys persist in Keychain; not deleted here
        // since they may still be in use by other models from the same provider.
    }

    private func loadAll() throws {
        let entries = try FileManager.default
            .contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> ConfiguredModel? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ConfiguredModel.self, from: data)
            }
            .sorted { ($0.displayName.isEmpty ? $0.modelID : $0.displayName)
                <  ($1.displayName.isEmpty ? $1.modelID : $1.displayName) }
        self.models = entries
    }

    private func write(_ model: ConfiguredModel) throws {
        let url = rootDirectory.appendingPathComponent("\(model.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(model)
        try data.write(to: url, options: .atomic)
    }
}
