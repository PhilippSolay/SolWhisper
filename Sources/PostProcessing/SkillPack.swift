import Foundation

/// One Markdown file with optional YAML frontmatter (between leading `---`
/// fences). Used for parent SKILL.md, shared/*.md, and types/*.md.
struct SkillModule: Sendable, Equatable {
    let frontmatter: [String: String]
    let body: String

    /// Frontmatter values used by the picker UI.
    var name: String { frontmatter["name"] ?? "" }
    var description: String { frontmatter["description"] ?? "" }
}

/// Hierarchical skill: parent + shared extractors + per-meeting-type modules.
/// Loaded from a folder shaped like `meeting-summary/` shipped in the bundle.
/// Renders into a single mega-prompt at summary time (alpha.5 execution model A).
struct SharedSkillModule: Sendable, Equatable {
    let filename: String
    let module: SkillModule
}

struct SkillPack: Sendable, Identifiable, Equatable {

    let id: String                       // folder name, e.g. "meeting-summary"
    let parent: SkillModule              // SKILL.md
    let shared: [SharedSkillModule]      // shared/*.md (ordered)
    let types: [String: SkillModule]     // "client-discovery" → types/client-discovery.md
    let isBuiltIn: Bool

    var name: String { parent.name.isEmpty ? id : parent.name }
    var description: String { parent.description }

    /// All available type IDs, sorted by frontmatter name (or filename).
    var typeIDs: [String] {
        types.keys.sorted()
    }

    /// Builds the system+user prompt pair for one meeting.
    ///
    /// - When `meetingType` is nil, the parent's full Step-1 classification
    ///   logic ships in the prompt and the LLM picks a type itself
    ///   (single-call auto-classify).
    /// - When `meetingType` is a known key in `types`, only that type module
    ///   is included; the rest are dropped.
    /// - When `meetingType` is non-nil but unknown, falls back to all-types
    ///   (graceful — never blocks the user).
    func renderPrompt(meetingType: String?,
                      transcript: String,
                      participants: [String],
                      context: String? = nil) -> (system: String, user: String) {

        var system = "You write meeting summaries in clean Markdown. Avoid editorializing.\n\n"
        system += "─── Skill: \(name) ───\n\n"
        system += parent.body
        system += "\n\n─── Shared modules ───\n"
        for entry in shared {
            system += "\n--- \(entry.filename) ---\n"
            system += entry.module.body
        }

        if let key = meetingType, let chosen = types[key] {
            system += "\n\n─── Type-specific module (pre-selected: \(key)) ───\n"
            system += chosen.body
            system += "\n\nThe user has explicitly set the meeting type to `\(key)`. Skip Step 1 of the parent skill and go directly to Step 2 onwards using the module above."
        } else {
            // No type set — bundle all type modules so the LLM can pick.
            system += "\n\n─── All type-specific modules (auto-classify) ───\n"
            for typeKey in typeIDs {
                if let mod = types[typeKey] {
                    system += "\n--- types/\(typeKey).md ---\n"
                    system += mod.body
                }
            }
            system += "\n\nFollow Step 1 of the parent skill to pick exactly one type from the modules above before proceeding."
        }

        let participantsLine = participants.isEmpty
            ? "Participants: not specified"
            : "Participants: \(participants.joined(separator: ", "))"

        let trimmedContext = (context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let contextBlock = trimmedContext.isEmpty
            ? ""
            : """

            Background you should know about this meeting:
            \(trimmedContext)

            """

        let user = """
        \(participantsLine)
        \(contextBlock)
        Transcript:

        <transcript>
        \(transcript)
        </transcript>
        """

        return (system, user)
    }

    // MARK: - Frontmatter parser

    /// Parses a Markdown file with optional YAML frontmatter.
    /// Frontmatter is delimited by `---` fences at the top of the file.
    /// Recognized keys are simple `key: value` pairs (no nested YAML).
    static func parseModule(_ contents: String) -> SkillModule {
        let lines = contents.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return SkillModule(frontmatter: [:], body: contents)
        }

        var frontmatter: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                i += 1
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                frontmatter[key] = value
            }
            i += 1
        }

        let body = lines[i...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillModule(frontmatter: frontmatter, body: body)
    }
}
