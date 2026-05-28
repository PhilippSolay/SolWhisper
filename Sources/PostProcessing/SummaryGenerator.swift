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
        let markdown = try await collectStream(
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
    /// `meetingType == nil` triggers a cheap classification pass first;
    /// the chosen type is then fed to the real summary call so the prompt
    /// only carries the one relevant type module instead of all of them.
    func generate(meeting: Meeting,
                  segments: [TranscriptSegment],
                  pack: SkillPack,
                  meetingType: String?) async throws -> Summary {
        let transcript = renderTranscriptForLLM(segments)
        let calendarAttendees = await CalendarIntegration.shared.attendeeNames(forMeeting: meeting)

        // Auto-classify pass: instead of bundling all ~10 type modules
        // (~21k tokens) into the summary prompt, do a tiny pre-call with
        // just the parent's routing rubric and a transcript head. Falls
        // back to the all-types-bundled approach if the pre-call fails
        // or returns something we can't validate.
        let resolvedTypeForPrompt: String?
        let classificationSource: String
        if let userPick = meetingType {
            resolvedTypeForPrompt = userPick
            classificationSource = "user-set"
        } else if let auto = await classifyMeetingType(pack: pack, transcript: transcript) {
            resolvedTypeForPrompt = auto
            classificationSource = "auto-llm-prepass"
        } else {
            resolvedTypeForPrompt = nil
            classificationSource = "auto-llm"
        }

        let (system, user) = pack.renderPrompt(
            meetingType: resolvedTypeForPrompt,
            transcript: transcript,
            participants: meeting.participants,
            context: meeting.context,
            calendarEventTitle: meeting.calendarEventTitle,
            calendarAttendees: calendarAttendees
        )

        let markdown = try await collectStream(
            messages: [
                .init(role: .system, content: system),
                .init(role: .user,   content: user)
            ],
            model: model,
            temperature: 0.2,
            maxTokens: 4_000
        )

        let sections = parseSections(markdown)
        let resolvedType = resolvedTypeForPrompt ?? extractTypeFromMarkdown(markdown)
        return Summary(
            skillId: pack.id,
            llmProvider: provider,
            llmModel: model,
            sections: sections,
            rawMarkdown: markdown,
            meetingType: resolvedType,
            classificationSource: classificationSource
        )
    }

    /// Cheap one-shot classification: parent rubric + ~3k char transcript
    /// head + the list of valid type ids → one token back. Validates the
    /// response against `pack.typeIDs`; returns nil on any mismatch so
    /// the caller can gracefully fall back to in-prompt classification.
    private func classifyMeetingType(pack: SkillPack,
                                      transcript: String) async -> String? {
        guard !pack.typeIDs.isEmpty else { return nil }
        let headLength = 3_000
        let head = transcript.count > headLength
            ? String(transcript.prefix(headLength))
            : transcript

        let (system, user) = pack.renderClassificationPrompt(transcriptHead: head)
        do {
            let raw = try await client.complete(
                messages: [
                    .init(role: .system, content: system),
                    .init(role: .user,   content: user)
                ],
                model: model,
                temperature: 0,
                maxTokens: 16
            )
            // Take the first whitespace-delimited token, strip punctuation.
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init) ?? ""
            let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:\"'`"))
            guard pack.typeIDs.contains(trimmed) else { return nil }
            return trimmed
        } catch {
            return nil
        }
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

    /// Drives the streaming API and concatenates chunks into the final
    /// markdown. Streaming is the safety net against URLSession's
    /// per-chunk timeout — a slow generation that emits even a single
    /// byte every 60s won't trip it. Clients without real SSE just yield
    /// the full text once (default protocol extension).
    private func collectStream(messages: [LLMMessage],
                                model: String,
                                temperature: Double,
                                maxTokens: Int) async throws -> String {
        var buffer = ""
        for try await chunk in client.stream(messages: messages,
                                              model: model,
                                              temperature: temperature,
                                              maxTokens: maxTokens) {
            buffer.append(chunk)
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapse consecutive same-speaker segments into one line. For a 1h+
    /// meeting Whisper produces ~900 segments — emitting a timestamp +
    /// speaker tag for each costs ~8-10k tokens of overhead that adds no
    /// signal to a holistic summary. We keep a timestamp at the start of
    /// each speaker block plus a sparse anchor every `timestampGapSec` so
    /// the model still has temporal landmarks for action items / decisions.
    private func renderTranscriptForLLM(_ segments: [TranscriptSegment]) -> String {
        let timestampGapSec: TimeInterval = 120

        var lines: [String] = []
        var currentLabel: String?
        var currentText: [String] = []
        var currentStart: TimeInterval = 0
        var lastTimestampStart: TimeInterval = -timestampGapSec * 2

        func flush() {
            guard let label = currentLabel, !currentText.isEmpty else { return }
            let body = currentText.joined(separator: " ")
            lines.append("\(formatTimestamp(currentStart)) \(label) \(body)")
            lastTimestampStart = currentStart
        }

        for segment in segments {
            let label: String
            switch segment.speaker {
            case .me: label = "[Me]"
            case .other: label = "[Other]"
            case .unknown: label = "[?]"
            }
            let text = (segment.cleanedText ?? segment.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let needNewBlock = label != currentLabel
            let needTimestampAnchor = segment.start - lastTimestampStart >= timestampGapSec

            if needNewBlock || needTimestampAnchor {
                flush()
                currentLabel = label
                currentText = [text]
                currentStart = segment.start
            } else {
                currentText.append(text)
            }
        }
        flush()
        return lines.joined(separator: "\n")
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
