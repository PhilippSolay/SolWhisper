import Foundation

/// Asks an LLM to propose `speakerLetter → realName` mappings for a
/// diarized transcript, using the meeting's Context field + participants
/// list + a few sample lines per speaker.
///
/// The suggester returns confidence-scored proposals; the user reviews
/// them in `SuggestNamesSheet` and accepts/edits before they hit the
/// `Meeting.speakerNames` map.
@MainActor
struct SpeakerNameSuggester {

    struct Suggestion: Identifiable {
        let id = UUID()
        let speakerID: String          // "A", "B", …
        let suggestedName: String?     // nil = LLM couldn't decide
        let confidence: Double         // 0.0 – 1.0
        let rationale: String          // one-line "why" from the LLM
        let sampleLines: [String]      // 3-5 representative segments
    }

    enum SuggesterError: Error, LocalizedError {
        case noSpeakers
        case noLLM
        case llmFailed(String)
        case unparseable(String)

        var errorDescription: String? {
            switch self {
            case .noSpeakers:        return "No diarized speakers in this transcript yet — run Diarize first."
            case .noLLM:             return "No LLM configured for summaries. Add a model in Settings → Models."
            case .llmFailed(let m):  return "LLM error: \(m)"
            case .unparseable(let s):return "Couldn't parse the LLM response. First 120 chars: \(s)"
            }
        }
    }

    /// Builds suggestions from a transcript and meeting context.
    /// `candidates` is the pool of possible names (calendar attendees +
    /// participants list, deduplicated by the caller).
    static func suggest(
        transcript: TranscriptDocument,
        meeting: Meeting,
        candidates: [String]
    ) async throws -> [Suggestion] {
        // Group segments by speaker letter; pick a few representative samples.
        var byLetter: [String: [TranscriptSegment]] = [:]
        for seg in transcript.segments {
            guard let letter = seg.speakerID, !letter.isEmpty else { continue }
            byLetter[letter, default: []].append(seg)
        }
        guard !byLetter.isEmpty else { throw SuggesterError.noSpeakers }

        guard let resolved = LLMResolver.resolve(.summary) else {
            throw SuggesterError.noLLM
        }

        let participants = (meeting.participants + candidates)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Build prompt: a per-speaker block with up to 5 of their longest
        // segments (that's where the model can pick up identity signals).
        var sample = ""
        let speakers = byLetter.keys.sorted()
        for letter in speakers {
            let segs = (byLetter[letter] ?? [])
                .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
                .prefix(5)
                .map { $0.cleanedText ?? $0.text }
            sample += "\n[Speaker \(letter)]\n"
            for line in segs {
                sample += "- \(line.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
        }

        let candidatesLine = participants.isEmpty
            ? "No specific candidate names were provided. If the transcript clearly identifies a speaker by name, use that; otherwise return null."
            : "Candidate names (pick from these unless the transcript clearly contradicts):\n- " + participants.joined(separator: "\n- ")

        let contextBlock = (meeting.context?.isEmpty ?? true)
            ? ""
            : "\nMeeting context (background the user provided):\n\(meeting.context!)\n"

        let system = """
        You are a meeting-attendance matcher. Given a diarized transcript with speaker letters (A, B, C…) and a list of candidate names, identify which name belongs to which speaker letter. Use only signals in the transcript: how they introduce themselves, what they're presenting, what role they play, what others address them as. Never guess based on demographics. When uncertain, return null.

        Output a single JSON object with this exact shape:
        {
          "mappings": [
            {"speaker": "A", "name": "Pierre" or null, "confidence": 0.0-1.0, "rationale": "one-line why"},
            ...
          ]
        }
        No prose, no markdown — just the JSON object.
        """

        let user = """
        \(contextBlock)
        \(candidatesLine)

        Diarized samples:
        \(sample)
        """

        let raw: String
        do {
            raw = try await resolved.client.complete(
                messages: [
                    .init(role: .system, content: system),
                    .init(role: .user,   content: user)
                ],
                model: resolved.modelID,
                temperature: 0.0,
                maxTokens: 1500
            )
        } catch {
            throw SuggesterError.llmFailed(error.localizedDescription)
        }

        guard let objStart = raw.firstIndex(of: "{"),
              let objEnd = raw.lastIndex(of: "}"),
              let data = String(raw[objStart...objEnd]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mappings = json["mappings"] as? [[String: Any]] else {
            throw SuggesterError.unparseable(String(raw.prefix(120)))
        }

        // Stitch in the sample lines so the user sees what the LLM was
        // looking at when it made each call.
        return mappings.compactMap { m -> Suggestion? in
            guard let letter = m["speaker"] as? String else { return nil }
            let name = m["name"] as? String
            let confidence: Double
            if let d = m["confidence"] as? Double { confidence = d }
            else if let n = m["confidence"] as? NSNumber { confidence = n.doubleValue }
            else { confidence = 0 }
            let rationale = (m["rationale"] as? String) ?? ""
            let lines = (byLetter[letter] ?? [])
                .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
                .prefix(3)
                .map { $0.cleanedText ?? $0.text }
            return Suggestion(
                speakerID: letter,
                suggestedName: (name?.isEmpty == false) ? name : nil,
                confidence: max(0, min(1, confidence)),
                rationale: rationale,
                sampleLines: Array(lines)
            )
        }.sorted { $0.speakerID < $1.speakerID }
    }
}
