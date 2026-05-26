import Foundation

/// Runs a `Skill` against a meeting transcript and produces a `Summary`.
struct SummaryGenerator {

    let client: LLMClient
    let provider: String          // "openrouter" or "ollama" — recorded into the Summary
    let model: String

    /// Default to Claude Sonnet 200k via OpenRouter for cloud users — handles
    /// up to ~12-hour meetings in one shot. Per-skill overrides win if set.
    static let defaultCloudModel = "anthropic/claude-3-5-sonnet"
    static let defaultLocalModel = "gemma-3"

    func generate(meeting: Meeting,
                  segments: [TranscriptSegment],
                  skill: Skill) async throws -> Summary {
        let transcript = renderTranscriptForLLM(segments)
        let prompt = skill.renderPrompt(transcript: transcript,
                                         participants: meeting.participants)

        let messages: [LLMMessage] = [
            .init(role: .system,
                  content: "You write meeting summaries in clean Markdown. Avoid editorializing."),
            .init(role: .user, content: prompt)
        ]
        let temperature = skill.defaultTemperature ?? 0.2
        let markdown = try await client.complete(
            messages: messages,
            model: skill.defaultLLMModel ?? model,
            temperature: temperature,
            maxTokens: 4_000
        )

        let sections = parseSections(markdown)
        return Summary(
            skillId: skill.id,
            llmProvider: provider,
            llmModel: skill.defaultLLMModel ?? model,
            sections: sections,
            rawMarkdown: markdown
        )
    }

    /// Skill-pack path — concatenates the pack's parent + shared + chosen
    /// type module into a single mega-prompt, runs one LLM call, and
    /// records `meetingType` + classification source on the returned Summary.
    /// `meetingType == nil` triggers in-prompt auto-classification.
    func generate(meeting: Meeting,
                  segments: [TranscriptSegment],
                  pack: SkillPack,
                  meetingType: String?) async throws -> Summary {
        let transcript = renderTranscriptForLLM(segments)
        let calendarAttendees = await CalendarIntegration.shared.attendeeNames(forMeeting: meeting)
        let (system, user) = pack.renderPrompt(
            meetingType: meetingType,
            transcript: transcript,
            participants: meeting.participants,
            context: meeting.context,
            calendarEventTitle: meeting.calendarEventTitle,
            calendarAttendees: calendarAttendees
        )

        let markdown = try await client.complete(
            messages: [
                .init(role: .system, content: system),
                .init(role: .user,   content: user)
            ],
            model: model,
            temperature: 0.2,
            maxTokens: 6_000
        )

        let sections = parseSections(markdown)
        let resolvedType = meetingType ?? extractTypeFromMarkdown(markdown)
        return Summary(
            skillId: pack.id,
            llmProvider: provider,
            llmModel: model,
            sections: sections,
            rawMarkdown: markdown,
            meetingType: resolvedType,
            classificationSource: meetingType == nil ? "auto-llm" : "user-set"
        )
    }

    /// Pulls the `**Type:**` value from the pack's standard markdown header.
    /// Robust to small format drift; returns nil if the field isn't present.
    private func extractTypeFromMarkdown(_ md: String) -> String? {
        for raw in md.components(separatedBy: "\n").prefix(20) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Matches `**Type:** client-discovery` or `Type: client-discovery`
            let stripped = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "*", with: "")
            guard stripped.lowercased().hasPrefix("type:") else { continue }
            let value = stripped
                .dropFirst("type:".count)
                .trimmingCharacters(in: .whitespaces)
            // Take only the first token (the type id), drop trailing comments.
            if let firstToken = value.split(whereSeparator: { $0.isWhitespace || $0 == "|" }).first {
                return String(firstToken)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func renderTranscriptForLLM(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment in
            let speaker: String
            switch segment.speaker {
            case .me: speaker = "[Me]"
            case .other: speaker = "[Other]"
            case .unknown: speaker = "[?]"
            }
            return "\(formatTimestamp(segment.start)) \(speaker) \(segment.cleanedText ?? segment.text)"
        }.joined(separator: "\n")
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Splits Markdown by `## ` headings into `SummarySection`s. Best-effort —
    /// LLM output that doesn't follow the template still surfaces in `rawMarkdown`.
    private func parseSections(_ markdown: String) -> [SummarySection] {
        var sections: [SummarySection] = []
        let lines = markdown.components(separatedBy: "\n")
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            let body = currentBody.joined(separator: "\n")
                                   .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(SummarySection(
                heading: heading,
                body: body,
                kind: classifyHeading(heading)
            ))
            currentBody.removeAll()
        }

        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }

    private func classifyHeading(_ heading: String) -> SummarySectionKind {
        let h = heading.lowercased()
        if h.contains("action") { return .actionItems }
        if h.contains("decision") { return .decisions }
        if h.contains("question") { return .openQuestions }
        if h.contains("next") { return .nextSteps }
        if h.contains("deadline") { return .deadlines }
        if h.contains("participant") { return .participants }
        if h.contains("overview") || h.contains("summary") { return .overview }
        if h.contains("note") { return .notes }
        return .custom
    }
}
