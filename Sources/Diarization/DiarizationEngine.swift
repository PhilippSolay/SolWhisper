import Foundation

/// One speaker-tagged time interval. Engines return an array of these
/// covering the audio file; we then map them onto our existing
/// `TranscriptSegment`s by time-overlap.
struct SpeakerSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String   // "A", "B", "C", … (or whatever the engine returns; normalized later)
}

/// Common interface for AssemblyAI / Deepgram / FluidAudio so the meeting
/// pipeline is engine-agnostic. All three return the same shape; whoever's
/// configured runs.
protocol DiarizationEngine: Sendable {
    /// Engine identifier persisted in `Meeting.diarizationEngine` as audit.
    static var providerID: String { get }

    /// Diarizes the audio at `audioURL`. The `progress` callback fires
    /// with values in 0...1 and may be coalesced (some engines only
    /// give "uploading / processing / done" coarse states).
    func diarize(audioURL: URL,
                  progress: @MainActor @escaping (Double) -> Void) async throws -> [SpeakerSegment]
}

/// Errors used by all engines so the UI can surface a consistent message.
enum DiarizationError: Error, LocalizedError {
    case missingApiKey(String)
    case http(status: Int, body: String)
    case decoding(String)
    case timeout(String)
    case notInstalled(String)
    case audioReadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .missingApiKey(let p):    return "Missing API key for \(p)."
        case .http(let s, let b):      return "HTTP \(s): \(b.prefix(200))"
        case .decoding(let m):         return "Diarization response decode failed: \(m)"
        case .timeout(let m):          return "Timed out: \(m)"
        case .notInstalled(let m):     return m
        case .audioReadFailed(let u):  return "Couldn't read audio at \(u.lastPathComponent)."
        }
    }
}

// MARK: - Speaker → Segment mapping

enum DiarizationMapper {

    /// Stamps `speakerID` onto each transcript segment based on time
    /// overlap with the engine's speaker segments. For a transcript
    /// segment, the speaker letter is whichever speaker has the most
    /// overlapping milliseconds. Ties go to the earliest-starting speaker.
    static func apply(_ speakerSegs: [SpeakerSegment],
                      to transcript: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !speakerSegs.isEmpty else { return transcript }

        return transcript.map { seg -> TranscriptSegment in
            let segDur = max(0.001, seg.end - seg.start)
            // Aggregate per-speaker overlap with this segment.
            var totals: [String: TimeInterval] = [:]
            for sp in speakerSegs {
                let overlapStart = max(seg.start, sp.start)
                let overlapEnd   = min(seg.end,   sp.end)
                if overlapEnd > overlapStart {
                    totals[sp.speakerID, default: 0] += (overlapEnd - overlapStart)
                }
            }
            guard let best = totals.max(by: { $0.value < $1.value }) else {
                return seg
            }
            // Require at least 20% of the segment to overlap before tagging
            // — short interjections shouldn't claim a whole sentence.
            guard best.value / segDur >= 0.2 else { return seg }
            var copy = seg
            copy.speakerID = best.key
            return copy
        }
    }

    /// Normalizes whatever the engine returned (numeric "0", "1", … or
    /// already letters) into "A", "B", "C", … in first-appearance order.
    /// Stable across re-runs as long as the engine emits speakers in the
    /// same order.
    static func normalizeToLetters(_ segs: [SpeakerSegment]) -> [SpeakerSegment] {
        var mapping: [String: String] = [:]
        var nextOrdinal: Int = 0
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

        return segs.map { sp in
            if let mapped = mapping[sp.speakerID] {
                return SpeakerSegment(start: sp.start, end: sp.end, speakerID: mapped)
            }
            let letter: String
            if nextOrdinal < alphabet.count {
                letter = String(alphabet[nextOrdinal])
            } else {
                letter = "S\(nextOrdinal)"   // overflow safeguard
            }
            nextOrdinal += 1
            mapping[sp.speakerID] = letter
            return SpeakerSegment(start: sp.start, end: sp.end, speakerID: letter)
        }
    }
}
