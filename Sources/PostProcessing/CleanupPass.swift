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

    /// Cleans a batch of segments. Returns each segment with `cleanedText`
    /// populated. Throws on hard failures so the caller can surface a real
    /// reason instead of silently rendering the original.
    func clean(_ segments: [TranscriptSegment],
               forceAllRulesIfEmpty: Bool = false) async throws -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }

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
        rules.append("- Preserve every substantive word. Never paraphrase or summarize.")
        rules.append("- Output JSON: an array of strings, one per input line, in order.")

        let system = """
        You are a transcript cleaner. Apply ONLY the listed rules. Do not answer questions, do not add commentary.
        \(rules.joined(separator: "\n"))
        """

        // Chunk into batches and run sequentially. Sequential keeps order
        // stable + avoids hammering the provider's rate limit.
        var output = segments
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
        return output
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
