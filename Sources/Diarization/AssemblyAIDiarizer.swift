import Foundation

/// AssemblyAI diarization client. Uses their `/v2/upload` + `/v2/transcript`
/// endpoints with `speaker_labels=true`. We discard AssemblyAI's STT output
/// (WhisperKit is canonical) and use only the `utterances[]` blocks for
/// speaker letters.
///
/// API key lives in Keychain under the `assemblyAI` slot.
struct AssemblyAIDiarizer: DiarizationEngine {

    static let providerID = "assemblyai"
    static let uploadURL  = URL(string: "https://api.assemblyai.com/v2/upload")!
    static let transcriptURL = URL(string: "https://api.assemblyai.com/v2/transcript")!

    /// Polling cadence + max wait. 5 min ceiling so a stuck job doesn't
    /// hang the UI thread forever.
    static let pollIntervalSec: UInt64 = 3
    static let maxPollAttempts: Int = 100   // 100 × 3s = 5 min

    static let apiKeyKeychainKey = "diarizer.assemblyai.apiKey"

    func diarize(audioURL: URL,
                  progress: @MainActor @escaping (Double) -> Void) async throws -> [SpeakerSegment] {
        let apiKey = (try? KeychainStore.string(forKey: Self.apiKeyKeychainKey)) ?? ""
        guard !apiKey.isEmpty else { throw DiarizationError.missingApiKey("assemblyai") }

        // 1. Upload the audio file. AssemblyAI's upload endpoint is a raw
        // POST of the bytes — no multipart, no metadata.
        guard let audioBytes = try? Data(contentsOf: audioURL) else {
            throw DiarizationError.audioReadFailed(audioURL)
        }
        await MainActor.run { progress(0.05) }

        var upReq = URLRequest(url: Self.uploadURL)
        upReq.httpMethod = "POST"
        upReq.setValue(apiKey, forHTTPHeaderField: "authorization")
        upReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upReq.httpBody = audioBytes

        let (upData, upResponse) = try await URLSession.shared.data(for: upReq)
        if let http = upResponse as? HTTPURLResponse, http.statusCode >= 400 {
            throw DiarizationError.http(status: http.statusCode,
                                          body: String(data: upData, encoding: .utf8) ?? "")
        }
        guard let upJSON = try? JSONSerialization.jsonObject(with: upData) as? [String: Any],
              let uploadURL = upJSON["upload_url"] as? String else {
            throw DiarizationError.decoding("upload response missing upload_url")
        }
        await MainActor.run { progress(0.30) }

        // 2. Submit transcript job with speaker_labels=true.
        var jobReq = URLRequest(url: Self.transcriptURL)
        jobReq.httpMethod = "POST"
        jobReq.setValue(apiKey, forHTTPHeaderField: "authorization")
        jobReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "audio_url": uploadURL,
            "speaker_labels": true
        ]
        jobReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (jobData, jobResponse) = try await URLSession.shared.data(for: jobReq)
        if let http = jobResponse as? HTTPURLResponse, http.statusCode >= 400 {
            throw DiarizationError.http(status: http.statusCode,
                                          body: String(data: jobData, encoding: .utf8) ?? "")
        }
        guard let jobJSON = try? JSONSerialization.jsonObject(with: jobData) as? [String: Any],
              let jobID = jobJSON["id"] as? String else {
            throw DiarizationError.decoding("job response missing id")
        }
        await MainActor.run { progress(0.40) }

        // 3. Poll for completion.
        let pollURL = Self.transcriptURL.appendingPathComponent(jobID)
        var pollReq = URLRequest(url: pollURL)
        pollReq.setValue(apiKey, forHTTPHeaderField: "authorization")

        for attempt in 0..<Self.maxPollAttempts {
            try await Task.sleep(nanoseconds: Self.pollIntervalSec * 1_000_000_000)
            let (data, response) = try await URLSession.shared.data(for: pollReq)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw DiarizationError.http(status: http.statusCode,
                                              body: String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                throw DiarizationError.decoding("poll response missing status")
            }
            // Smooth fake progress between 0.4 and 0.95 while we wait.
            let frac = 0.40 + min(Double(attempt) / 30.0, 0.55)
            await MainActor.run { progress(frac) }

            switch status {
            case "completed":
                return parseUtterances(json: json)
            case "error":
                let err = json["error"] as? String ?? "AssemblyAI returned error status"
                throw DiarizationError.http(status: 0, body: err)
            case "queued", "processing":
                continue
            default:
                continue
            }
        }
        throw DiarizationError.timeout("AssemblyAI job didn't finish in 5 minutes")
    }

    /// Pulls `utterances[]` from the completed transcript response and
    /// converts each to a `SpeakerSegment`. AssemblyAI returns ms.
    private func parseUtterances(json: [String: Any]) -> [SpeakerSegment] {
        guard let utterances = json["utterances"] as? [[String: Any]] else { return [] }
        let raw: [SpeakerSegment] = utterances.compactMap { u in
            guard let startMs = u["start"] as? Int,
                  let endMs   = u["end"]   as? Int,
                  let speaker = u["speaker"] as? String else { return nil }
            return SpeakerSegment(
                start: TimeInterval(startMs) / 1000.0,
                end:   TimeInterval(endMs) / 1000.0,
                speakerID: speaker
            )
        }
        return DiarizationMapper.normalizeToLetters(raw)
    }
}
