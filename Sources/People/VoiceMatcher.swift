import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Auto-names diarized speakers by comparing their embeddings to saved
/// VoiceProfile fingerprints via cosine similarity. Run after diarization
/// has populated `speakerID` on transcript segments.
///
/// Threshold: similarity ≥ 0.70 wins (FluidAudio's WeSpeaker model is
/// L2-normalized so cosine ≡ dot product). Below that, the speaker stays
/// unmapped and the user can rename manually.
@MainActor
enum VoiceMatcher {

    /// One match decision the runner returns.
    struct Match {
        let speakerLetter: String
        let profileName: String
        let confidence: Double
    }

    static let matchThreshold: Double = 0.70

    /// Returns the matches found + writes them onto `meeting.speakerNames`.
    /// `audioURL` should be the canonical mixed `audio.m4a` (or import audio).
    static func match(meeting: Meeting,
                      transcript: TranscriptDocument,
                      audioURL: URL,
                      store: MeetingStore,
                      profileStore: VoiceProfileStore) async -> [Match] {
        guard #available(macOS 14.0, *) else { return [] }
        #if canImport(FluidAudio)
        // Only profiles with stored embeddings can participate.
        let candidates = profileStore.profiles.filter { $0.hasEmbedding }
        guard !candidates.isEmpty else { return [] }

        // Group transcript segments by speaker letter and pick longest first.
        var byLetter: [String: [TranscriptSegment]] = [:]
        for seg in transcript.segments {
            guard let letter = seg.speakerID, !letter.isEmpty else { continue }
            byLetter[letter, default: []].append(seg)
        }
        guard !byLetter.isEmpty else { return [] }

        // Use the streaming resampler for the same reason VoiceProfileEmbedder
        // does — the synchronous AudioConverter path hangs on long files,
        // which silently disabled auto-matching for every meeting longer
        // than a few minutes.
        let samples: [Float]
        do {
            samples = try await StreamingAudioResampler.resampleToMonoFloat32(
                url: audioURL,
                progress: { _ in }
            )
        } catch {
            DebugLog.shared.log(icon: "🎯", label: "Voice match read failed",
                                value: "\(error)", ok: false)
            return []
        }

        var matches: [Match] = []
        let sampleRate: Float = 16_000
        let target = Int(20 * sampleRate)

        // For each detected speaker, build a clip and embed it once.
        for (letter, segs) in byLetter {
            // Skip if the user already named this speaker manually.
            if meeting.speakerNames?[letter] != nil { continue }

            let sorted = segs.sorted { ($0.end - $0.start) > ($1.end - $1.start) }
            var clip: [Float] = []
            for s in sorted {
                let lo = max(0, Int(Float(s.start) * sampleRate))
                let hi = min(samples.count, Int(Float(s.end) * sampleRate))
                if hi <= lo { continue }
                clip.append(contentsOf: samples[lo..<hi])
                if clip.count >= target { break }
            }
            guard !clip.isEmpty else { continue }

            let speakerEmbedding: [Float]
            do {
                speakerEmbedding = try await FluidAudioDiarizer.extractEmbedding(samples: clip)
            } catch {
                continue
            }

            // Compare against every profile's embedding.
            var best: (name: String, sim: Double)? = nil
            for profile in candidates {
                guard let data = profile.embedding,
                      let dim = profile.embeddingDim else { continue }
                let saved = VoiceProfileEmbedder.dataToFloats(data, dim: dim)
                guard saved.count == speakerEmbedding.count else { continue }
                let sim = cosine(speakerEmbedding, saved)
                if best == nil || sim > best!.sim {
                    best = (profile.name, sim)
                }
            }
            if let best, best.sim >= matchThreshold {
                matches.append(Match(
                    speakerLetter: letter,
                    profileName: best.name,
                    confidence: best.sim
                ))
            }
        }

        guard !matches.isEmpty else { return [] }

        // Persist matches onto the meeting (don't overwrite user edits).
        var updated = meeting
        var names = updated.speakerNames ?? [:]
        for m in matches where names[m.speakerLetter] == nil {
            names[m.speakerLetter] = m.profileName
        }
        updated.speakerNames = names.isEmpty ? nil : names
        updated.updatedAt = Date()
        try? store.update(updated)
        DebugLog.shared.log(icon: "🎯", label: "Voice match",
                            value: matches.map { "\($0.speakerLetter)→\($0.profileName) (\(String(format: "%.0f%%", $0.confidence * 100)))" }.joined(separator: ", "))
        return matches
        #else
        return []
        #endif
    }

    /// Cosine similarity. Both inputs assumed L2-normalized (FluidAudio's
    /// WeSpeaker output already is), so this is just a dot product, but we
    /// normalize defensively in case future embedders aren't.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var an: Double = 0
        var bn: Double = 0
        for i in 0..<a.count {
            dot += Double(a[i]) * Double(b[i])
            an  += Double(a[i]) * Double(a[i])
            bn  += Double(b[i]) * Double(b[i])
        }
        let denom = (an.squareRoot() * bn.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
