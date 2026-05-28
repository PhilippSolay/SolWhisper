import Foundation

/// Deepgram diarization via their `/v1/listen` endpoint with `diarize=true`.
/// Reuses the existing Deepgram API key (`deepgramApiKey` UserDefault) so
/// users who already configured Deepgram for STT Short get diarization for
/// free. We only consume the `words[]` field with `speaker: int` per word —
/// Deepgram's transcript text is discarded; WhisperKit remains canonical.
struct DeepgramDiarizer: DiarizationEngine {

    static let providerID = "deepgram"
    static let endpoint = URL(string: "https://api.deepgram.com/v1/listen?diarize=true&punctuate=false&utterances=true")!

    func diarize(audioURL: URL,
                  progress: @MainActor @escaping (Double) -> Void) async throws -> [SpeakerSegment] {
        // Reuse the existing Deepgram key from UserDefaults (legacy STT key).
        let apiKey = UserDefaults.standard.string(forKey: "deepgramApiKey") ?? ""
        guard !apiKey.isEmpty else { throw DiarizationError.missingApiKey("deepgram") }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw DiarizationError.audioReadFailed(audioURL)
        }
        await MainActor.run { progress(0.05) }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        // Accepts any content type Deepgram supports; let it sniff the WAV header.
        req.setValue(mimeType(for: audioURL), forHTTPHeaderField: "Content-Type")
        // Long timeout — diarization can take ~RT-of-audio for cloud paths.
        req.timeoutInterval = 600

        // Stream from disk + report real upload progress so the UI bar
        // doesn't park at a single tick for the entire multi-minute
        // transfer of a 100+ MB recording.
        let uploadProgress = UploadProgressDelegate()
        uploadProgress.onProgress = { fraction in
            // 0.05…0.55 covers the upload phase; the post-upload ingest
            // wait then jumps to 0.85 once Deepgram returns.
            Task { @MainActor in progress(0.05 + 0.50 * fraction) }
        }

        let (data, response) = try await URLSession.shared.upload(
            for: req,
            fromFile: audioURL,
            delegate: uploadProgress
        )
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DiarizationError.http(status: http.statusCode,
                                          body: String(data: data, encoding: .utf8) ?? "")
        }
        await MainActor.run { progress(0.85) }

        // Deepgram returns utterances when `utterances=true` is set. We
        // prefer that over per-word grouping for less noisy speaker
        // boundaries. Each utterance has `start`, `end`, `speaker`.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any] else {
            throw DiarizationError.decoding("no results block")
        }

        if let utterances = results["utterances"] as? [[String: Any]] {
            let raw: [SpeakerSegment] = utterances.compactMap { u in
                guard let start = u["start"] as? Double,
                      let end   = u["end"] as? Double else { return nil }
                let spk: String
                if let n = u["speaker"] as? Int { spk = String(n) }
                else if let s = u["speaker"] as? String { spk = s }
                else { spk = "?" }
                return SpeakerSegment(start: start, end: end, speakerID: spk)
            }
            return DiarizationMapper.normalizeToLetters(raw)
        }

        // Fallback: aggregate words by consecutive speaker into spans.
        if let channels = results["channels"] as? [[String: Any]],
           let alts = channels.first?["alternatives"] as? [[String: Any]],
           let words = alts.first?["words"] as? [[String: Any]] {
            var segments: [SpeakerSegment] = []
            var current: (start: Double, end: Double, speaker: String)?
            for w in words {
                guard let start = w["start"] as? Double,
                      let end   = w["end"] as? Double else { continue }
                let spk: String
                if let n = w["speaker"] as? Int { spk = String(n) }
                else if let s = w["speaker"] as? String { spk = s }
                else { continue }
                if let cur = current, cur.speaker == spk {
                    current = (cur.start, end, spk)
                } else {
                    if let cur = current {
                        segments.append(SpeakerSegment(start: cur.start, end: cur.end,
                                                       speakerID: cur.speaker))
                    }
                    current = (start, end, spk)
                }
            }
            if let cur = current {
                segments.append(SpeakerSegment(start: cur.start, end: cur.end,
                                               speakerID: cur.speaker))
            }
            return DiarizationMapper.normalizeToLetters(segments)
        }

        return []
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":     return "audio/wav"
        case "mp3":     return "audio/mpeg"
        case "m4a":     return "audio/mp4"
        case "flac":    return "audio/flac"
        case "ogg":     return "audio/ogg"
        case "aac":     return "audio/aac"
        case "aiff", "aif": return "audio/aiff"
        case "mp4":     return "video/mp4"
        default:        return "audio/wav"
        }
    }
}
