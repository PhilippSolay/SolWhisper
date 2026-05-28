import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Captures a 256-dim speaker embedding from a slice of meeting audio
/// (the segments where Speaker X spoke) and stores it on a VoiceProfile.
///
/// macOS 14+ only — FluidAudio's floor. Older systems get a graceful
/// "name only" profile with no embedding.
@MainActor
enum VoiceProfileEmbedder {

    enum EmbedError: Error, LocalizedError {
        case unsupportedOS
        case audioReadFailed(URL)
        case noSegmentsForSpeaker(String)
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Voice fingerprinting requires macOS 14 or later. The profile was saved as name-only."
            case .audioReadFailed(let u):
                return "Couldn't read audio at \(u.lastPathComponent)."
            case .noSegmentsForSpeaker(let s):
                return "No segments found for Speaker \(s) in this transcript."
            case .underlying(let m):
                return m
            }
        }
    }

    /// Captures an embedding from the segments where the named speaker
    /// letter appears in the given transcript. Concatenates up to ~30s
    /// of their audio (longest segments first) for a stable embedding.
    static func capture(profile: VoiceProfile,
                        speakerLetter: String,
                        in transcript: TranscriptDocument,
                        audioURL: URL,
                        store: VoiceProfileStore) async throws {
        guard #available(macOS 14.0, *) else {
            throw EmbedError.unsupportedOS
        }
        #if canImport(FluidAudio)
        // 1. Pick the longest segments for this speaker — embeddings are
        // more reliable on continuous speech than on short interjections.
        let segs = transcript.segments
            .filter { $0.speakerID == speakerLetter }
            .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
        guard !segs.isEmpty else {
            throw EmbedError.noSegmentsForSpeaker(speakerLetter)
        }

        // 2. Load + resample the full audio file once, then slice in
        // sample space. Stop accumulating once we have ~30s of audio.
        // We use the streaming resampler here (chunked AVAudioConverter,
        // reports progress, honours cancellation). The previous direct
        // call to FluidAudio's `AudioConverter().resampleAudioFile(...)`
        // silently hung on long recordings, which is why no profile in
        // the user's `~/Library/Application Support/SolWhisper/Voices/`
        // folder ever had an `embedding` field — capture started, the
        // file load deadlocked, and the catch in MeetingDetailView only
        // logged a line nobody saw.
        let samples: [Float]
        do {
            samples = try await StreamingAudioResampler.resampleToMonoFloat32(
                url: audioURL,
                progress: { _ in }
            )
        } catch {
            throw EmbedError.audioReadFailed(audioURL)
        }
        let sampleRate: Float = 16_000
        var clip: [Float] = []
        let target = Int(30 * sampleRate)
        for s in segs {
            let lo = max(0, Int(Float(s.start) * sampleRate))
            let hi = min(samples.count, Int(Float(s.end) * sampleRate))
            if hi <= lo { continue }
            clip.append(contentsOf: samples[lo..<hi])
            if clip.count >= target { break }
        }
        guard !clip.isEmpty else {
            throw EmbedError.noSegmentsForSpeaker(speakerLetter)
        }

        // 3. Run the embedder on the concatenated clip.
        let embedding: [Float]
        do {
            embedding = try await FluidAudioDiarizer.extractEmbedding(samples: clip)
        } catch {
            throw EmbedError.underlying(error.localizedDescription)
        }

        // 4. Persist embedding bytes onto the profile.
        var updated = profile
        updated.embedding = floatsToData(embedding)
        updated.embeddingDim = embedding.count
        store.update(updated)
        DebugLog.shared.log(icon: "👥", label: "Voiceprint captured",
                            value: "\(profile.name) · \(embedding.count) dims · \(clip.count) samples")
        #else
        throw EmbedError.underlying("FluidAudio package not linked.")
        #endif
    }

    // MARK: - Encoding helpers

    /// Packs a `[Float]` into a `Data` blob (little-endian, native float).
    private static func floatsToData(_ floats: [Float]) -> Data {
        return floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func dataToFloats(_ data: Data, dim: Int) -> [Float] {
        let count = min(dim, data.count / MemoryLayout<Float>.size)
        return data.withUnsafeBytes { raw -> [Float] in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(ptr.prefix(count))
        }
    }
}
