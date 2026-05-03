import Foundation

/// User-defined or built-in summary template. Skills are loaded from JSON —
/// built-ins from the bundle's `Resources/Skills/`, user skills from
/// `~/Library/Application Support/SolWhisper/Skills/`.
///
/// v0.4 ships free-form prompt templates only. Custom declarable form fields
/// (the original §3.5 design) are deferred to v0.5+.
struct Skill: Codable, Identifiable, Equatable, Sendable {
    let id: String                     // stable slug, eg "generic" or "sales-call"
    var name: String                   // human label
    var description: String
    var promptTemplate: String         // body sent to the LLM
    var outputTemplate: String         // markdown skeleton (optional)
    var defaultLLMProvider: String?    // "openrouter" or "ollama"
    var defaultLLMModel: String?
    var defaultTemperature: Double?
    var isBuiltIn: Bool

    /// Substitutes `{{transcript}}` and `{{participants}}` in the prompt
    /// template. Other placeholders pass through untouched (LLM ignores them).
    func renderPrompt(transcript: String, participants: [String]) -> String {
        var out = promptTemplate
        out = out.replacingOccurrences(of: "{{transcript}}",
                                        with: transcript)
        out = out.replacingOccurrences(of: "{{participants}}",
                                        with: participants.joined(separator: ", "))
        return out
    }
}
