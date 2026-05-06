import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Local diarization via FluidAudio (CoreML-converted pyannote v3 + WeSpeaker
/// embeddings). Fully on-device — no audio leaves the machine.
///
/// macOS 14+ requirement (FluidAudio's package floor). On macOS 13 we
/// throw `notInstalled` so the UI can guide the user to a cloud engine.
struct FluidAudioDiarizer: DiarizationEngine {

    static let providerID = "fluidaudio"

    func diarize(audioURL: URL,
                  progress: @MainActor @escaping (Double) -> Void) async throws -> [SpeakerSegment] {
        guard #available(macOS 14.0, *) else {
            throw DiarizationError.notInstalled(
                "Local diarization (FluidAudio) requires macOS 14 or later. Pick AssemblyAI or Deepgram in Settings → Models → Diarization."
            )
        }
        #if canImport(FluidAudio)
        return try await runFluidAudio(audioURL: audioURL, progress: progress)
        #else
        throw DiarizationError.notInstalled(
            "Local diarization (FluidAudio) Swift package isn't linked in this build."
        )
        #endif
    }

    #if canImport(FluidAudio)
    @available(macOS 14.0, *)
    private func runFluidAudio(audioURL: URL,
                                progress: @MainActor @escaping (Double) -> Void) async throws -> [SpeakerSegment] {
        // 1. Resample to 16 kHz mono Float (FluidAudio's required input).
        await MainActor.run { progress(0.05) }
        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(audioURL)
        } catch {
            throw DiarizationError.audioReadFailed(audioURL)
        }
        await MainActor.run { progress(0.20) }

        // 2. Download (or load cached) CoreML models. First call after
        // install pulls ~30-50 MB; subsequent calls are instant.
        let models: DiarizerModels
        do {
            models = try await DiarizerModels.downloadIfNeeded()
        } catch {
            throw DiarizationError.notInstalled(
                "Couldn't load FluidAudio models: \(error.localizedDescription)"
            )
        }
        await MainActor.run { progress(0.40) }

        // 3. Initialize the manager and run.
        let manager = DiarizerManager(config: .default)
        manager.initialize(models: consume models)
        await MainActor.run { progress(0.55) }

        let result: DiarizationResult
        do {
            result = try await manager.performCompleteDiarization(samples, sampleRate: 16_000)
        } catch {
            throw DiarizationError.http(status: 0,
                                          body: "FluidAudio diarization failed: \(error.localizedDescription)")
        }
        await MainActor.run { progress(0.95) }

        // 4. Convert to our shape; normalize speaker IDs to canonical letters.
        let raw = result.segments.map { seg -> SpeakerSegment in
            SpeakerSegment(
                start: TimeInterval(seg.startTimeSeconds),
                end:   TimeInterval(seg.endTimeSeconds),
                speakerID: seg.speakerId
            )
        }
        return DiarizationMapper.normalizeToLetters(raw)
    }

    /// Static helper used by `VoiceProfileEmbedder` to extract a single
    /// embedding from a slice of audio. Reuses the same model load.
    @available(macOS 14.0, *)
    static func extractEmbedding(samples: [Float]) async throws -> [Float] {
        let models = try await DiarizerModels.downloadIfNeeded()
        let manager = DiarizerManager(config: .default)
        manager.initialize(models: consume models)
        return try manager.extractSpeakerEmbedding(from: samples)
    }
    #endif
}
