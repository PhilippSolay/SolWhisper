import Foundation

/// LLM-driven cleanup of meeting transcripts: filler removal + light grammar.
/// Sprint 5 deliverable. Re-uses the existing dictation-mode cleanup-level
/// toggles from Settings → AI Polish (`polishRemoveFiller`, `polishFixPunctuation`,
/// `polishFixGrammar`) so the user has one set of controls, not two.
///
/// Chunks segments into batches so long meetings don't overflow the LLM's
/// max output tokens (a 1h+ meeting can have 200+ segments — sending them all
/// at once produced a count-mismatched array and the cleanup silently no-op'd).
struct CleanupPass {

    let client: LLMClient
    let model: String
    let temperature: Double = 0.0
    /// Per-batch max output. Tuned so 50 segments × ~50 tokens each comfortably
    /// fits with headroom for verbose/grammar-fix expansion.
    let maxTokensPerBatch: Int = 4_000
    /// How many transcript lines per LLM call.
    let batchSize: Int = 50

    /// Per-run audit returned by `clean(...)`. Surfaced in the UI so the
    /// user can see exactly what changed (artifacts dropped, segments
    /// modified, total batches, time taken, etc.).
    struct Report {
        let totalSegments: Int
        let artifactsDropped: Int
        let segmentsModified: Int
        let segmentsUnchanged: Int
        let segmentsBlanked: Int
        let batchCount: Int
        let elapsedSeconds: Double
        let providerLabel: String
        let modelID: String
        let rulesEnabled: [String]
        let avgWordsBefore: Double
        let avgWordsAfter: Double

        var wordReductionPct: Double {
            guard avgWordsBefore > 0 else { return 0 }
            return max(0, (avgWordsBefore - avgWordsAfter) / avgWordsBefore * 100)
        }
    }

    enum CleanError: Error, LocalizedError {
        case noRulesEnabled
        case llmError(String)
        case unparseableResponse(rawSnippet: String)
        case partial(reason: String, completedCount: Int, totalCount: Int)

        var errorDescription: String? {
            switch self {
            case .noRulesEnabled:
                return "No cleanup rules enabled (filler removal, punctuation, or grammar)."
            case .llmError(let m):
                return "LLM error: \(m)"
            case .unparseableResponse(let s):
                return "LLM returned no parseable JSON. First 120 chars: \(s)"
            case .partial(let r, let done, let total):
                return "Partial cleanup: \(done)/\(total) segments cleaned before \(r)."
            }
        }
    }

    /// Regex matching segments whose entire content is a non-speech tag
    /// emitted by WhisperKit / similar STTs — `[coughing]`, `[BLANK_AUDIO]`,
    /// `(birds chirping)`, `<music>`, etc. We strip these client-side
    /// before the LLM call so they never count as a "segment to clean."
    private static let nonSpeechArtifactPattern = #"^\s*[\[\(<][^\]\)>]*[\]\)>][\s\.,;:!?]*$"#

    /// Returns true when the segment's text is *only* a non-speech artifact.
    private static func isNonSpeechArtifact(_ text: String) -> Bool {
        text.range(of: nonSpeechArtifactPattern, options: .regularExpression) != nil
    }

    /// Backwards-compatible wrapper: returns just the cleaned segments.
    /// New callers should use `cleanWithReport(...)` to get the audit blob.
    func clean(_ segments: [TranscriptSegment],
               forceAllRulesIfEmpty: Bool = false) async throws -> [TranscriptSegment] {
        let result = try await cleanWithReport(segments, forceAllRulesIfEmpty: forceAllRulesIfEmpty)
        return result.segments
    }

    /// Cleans a batch of segments AND returns a Report describing what
    /// changed. Use this from the manual Clean button so the UI can show
    /// the user exactly what got modified / dropped.
    func cleanWithReport(_ segments: [TranscriptSegment],
                          forceAllRulesIfEmpty: Bool = false) async throws -> (segments: [TranscriptSegment], report: Report) {
        let start = Date()
        guard !segments.isEmpty else {
            let r = Report(totalSegments: 0, artifactsDropped: 0, segmentsModified: 0,
                           segmentsUnchanged: 0, segmentsBlanked: 0, batchCount: 0,
                           elapsedSeconds: 0, providerLabel: "—", modelID: model,
                           rulesEnabled: [], avgWordsBefore: 0, avgWordsAfter: 0)
            return (segments, r)
        }

        var removeFiller = UserDefaults.standard.bool(forKey: "polishRemoveFiller")
        var fixPunct = UserDefaults.standard.bool(forKey: "polishFixPunctuation")
        var fixGrammar = UserDefaults.standard.bool(forKey: "polishFixGrammar")
        if forceAllRulesIfEmpty, !(removeFiller || fixPunct || fixGrammar) {
            removeFiller = true
            fixPunct = true
            fixGrammar = true
        }
        guard removeFiller || fixPunct || fixGrammar else {
            throw CleanError.noRulesEnabled
        }

        var rules: [String] = []
        if removeFiller { rules.append("- Remove filler words (um, uh, like, you know, basically, I mean, right, well).") }
        if fixPunct { rules.append("- Fix punctuation and capitalization.") }
        if fixGrammar { rules.append("- Fix obvious grammar errors but keep the speaker's voice.") }
        // WhisperKit / other STT engines emit non-speech artifact tokens
        // when the audio has no speech. These should NEVER appear in a
        // cleaned transcript — return an empty string so the line drops.
        rules.append("- Drop non-speech artifacts: any line whose entire content is a bracketed or parenthesized tag (e.g. [coughing], [BLANK_AUDIO], [silence], [music], [typing], [typing sounds], (birds chirping), [laughter], [sighs], <music>, etc.). Return an empty string \"\" for those lines.")
        rules.append("- Preserve every substantive *spoken* word. Never paraphrase or summarize. (Non-speech bracketed tags are NOT spoken words.)")
        rules.append("- Output JSON: an object keyed by line index. See the user message for format.")

        let system = """
        You are a transcript cleaner. Apply ONLY the listed rules. Do not answer questions, do not add commentary.
        \(rules.joined(separator: "\n"))
        """

        // Pre-pass: blank out segments that are pure non-speech artifacts.
        // No LLM call needed; deterministic and free.
        var output = segments
        var artifactCount = 0
        for i in output.indices {
            if Self.isNonSpeechArtifact(output[i].text) {
                output[i].cleanedText = ""
                artifactCount += 1
            }
        }
        if artifactCount > 0 {
            // DebugLog is @MainActor — hop on for the call.
            let drops = artifactCount
            await MainActor.run {
                DebugLog.shared.log(icon: "🧹", label: "Cleanup pre-filter",
                                    value: "dropped \(drops) non-speech artifact segments")
            }
        }

        // Chunk into batches and run sequentially. Sequential keeps order
        // stable + avoids hammering the provider's rate limit.
        var lastError: CleanError?
        var batches = 0
        var doneCount = 0
        for batchStart in stride(from: 0, to: segments.count, by: batchSize) {
            let end = min(batchStart + batchSize, segments.count)
            let slice = Array(segments[batchStart..<end])
            batches += 1
            do {
                let cleanedSlice = try await cleanOneBatch(slice, system: system)
                for (i, text) in cleanedSlice.enumerated() {
                    // Don't overwrite the pre-filtered artifact blanks; if
                    // the LLM returned text for a line we already marked
                    // empty, keep our verdict (artifact regex is reliable).
                    if Self.isNonSpeechArtifact(slice[i].text) { continue }
                    var m = output[batchStart + i]
                    m.cleanedText = text
                    output[batchStart + i] = m
                }
                doneCount += slice.count
            } catch let err as CleanError {
                lastError = err
                Task { @MainActor in
                    DebugLog.shared.log(icon: "🧹", label: "Cleanup batch failed",
                                        value: "batch=\(batches) reason=\(err.localizedDescription)",
                                        ok: false)
                }
                // Stop on first hard failure so we don't keep paying for
                // calls when the model can't produce parseable output.
                break
            }
        }

        if let lastError, doneCount == 0 {
            throw lastError
        }
        if let lastError {
            throw CleanError.partial(reason: lastError.localizedDescription,
                                      completedCount: doneCount,
                                      totalCount: segments.count)
        }

        // Build the report by diffing input vs output.
        let report = makeReport(input: segments, output: output,
                                artifactsDropped: artifactCount,
                                batchCount: batches,
                                elapsedSeconds: Date().timeIntervalSince(start),
                                rulesEnabled: ruleLabels(removeFiller: removeFiller,
                                                          fixPunct: fixPunct,
                                                          fixGrammar: fixGrammar))
        return (output, report)
    }

    private func ruleLabels(removeFiller: Bool, fixPunct: Bool, fixGrammar: Bool) -> [String] {
        var out: [String] = []
        if removeFiller { out.append("Remove filler words") }
        if fixPunct     { out.append("Fix punctuation & capitalization") }
        if fixGrammar   { out.append("Fix grammar (preserve voice)") }
        return out
    }

    private func makeReport(input: [TranscriptSegment],
                             output: [TranscriptSegment],
                             artifactsDropped: Int,
                             batchCount: Int,
                             elapsedSeconds: Double,
                             rulesEnabled: [String]) -> Report {
        var modified = 0
        var blanked = 0
        var unchanged = 0
        var wordsBefore = 0
        var wordsAfter = 0
        for (a, b) in zip(input, output) {
            let beforeText = a.text
            let afterText = b.cleanedText ?? a.text
            let bw = beforeText.split(whereSeparator: \.isWhitespace).count
            let aw = afterText.split(whereSeparator: \.isWhitespace).count
            wordsBefore += bw
            wordsAfter  += aw
            if let cleaned = b.cleanedText {
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blanked += 1
                } else if cleaned != beforeText {
                    modified += 1
                } else {
                    unchanged += 1
                }
            } else {
                unchanged += 1
            }
        }
        let avgBefore = input.isEmpty ? 0 : Double(wordsBefore) / Double(input.count)
        let avgAfter  = input.isEmpty ? 0 : Double(wordsAfter)  / Double(input.count)
        return Report(
            totalSegments: input.count,
            artifactsDropped: artifactsDropped,
            segmentsModified: modified,
            segmentsUnchanged: unchanged,
            segmentsBlanked: blanked,
            batchCount: batchCount,
            elapsedSeconds: elapsedSeconds,
            providerLabel: providerLabelFromModel(),
            modelID: model,
            rulesEnabled: rulesEnabled,
            avgWordsBefore: avgBefore,
            avgWordsAfter: avgAfter
        )
    }

    /// Best-effort provider label inferred from the model identifier.
    /// (We don't have the providerLabel string here directly — the caller
    /// passes it in via the LLMResolver, but we'd need to thread that
    /// through. Cheap inference is fine for the report header.)
    private func providerLabelFromModel() -> String {
        let m = model.lowercased()
        if m.contains("/")            { return "openrouter" }
        if m.contains("claude")        { return "anthropic" }
        if m.contains("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") { return "openai" }
        if m.contains("gemini")        { return "google" }
        if m.contains("llama") || m.contains("groq") { return "groq" }
        return "model"
    }

    private func cleanOneBatch(_ slice: [TranscriptSegment],
                                system: String) async throws -> [String] {
        let numbered = slice.enumerated()
            .map { "[\($0.offset)] \($0.element.text)" }
            .joined(separator: "\n")
        // Indexed-object format survives the common case where the LLM drops
        // a line that was pure filler — we look up by key so a missing
        // index just keeps the original text instead of throwing an error.
        let user = """
        Clean each line below. The line index is in [brackets].

        Return a JSON object whose keys are the indices as strings and whose
        values are the cleaned text for that line. Example:
        {"0": "First cleaned line.", "1": "Second cleaned line."}

        Include every index from 0 to \(slice.count - 1). If a line is purely
        filler ("um", "uh", etc.) and would be empty after cleaning, return
        an empty string for that index — do NOT omit the key.

        No prose, no markdown — just the JSON object.

        ---
        \(numbered)
        """

        let raw: String
        do {
            raw = try await client.complete(
                messages: [
                    .init(role: .system, content: system),
                    .init(role: .user,   content: user)
                ],
                model: model,
                temperature: temperature,
                maxTokens: maxTokensPerBatch
            )
        } catch {
            throw CleanError.llmError(error.localizedDescription)
        }

        // Object form first (preferred). Falls back to array form for older
        // model behavior so we don't break installs mid-upgrade.
        if let objString = extractJSONObject(raw),
           let data = objString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (0..<slice.count).map { i -> String in
                if let val = dict[String(i)] as? String { return val }
                return slice[i].text   // missing key → keep original
            }
        }
        if let arrayString = extractJSONArray(raw),
           let data = arrayString.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            // Tolerate off-by-one: zip and keep originals for any leftover
            // positions. Better than throwing on a 49-vs-50 nit.
            return (0..<slice.count).map { i in
                i < arr.count ? arr[i] : slice[i].text
            }
        }

        throw CleanError.unparseableResponse(rawSnippet: String(raw.prefix(120)))
    }

    private func extractJSONObject(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}") else { return nil }
        return String(raw[start...end])
    }

    private func extractJSONArray(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]") else { return nil }
        return String(raw[start...end])
    }
}
