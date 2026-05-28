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
        // Phase budget for the progress bar:
        //   resample (0…0.40) — streaming, big % so long files have real motion
        //   model load (0.40…0.55)
        //   diarize (0.55…0.95)
        //   normalize (0.95…1.0)
        //
        // The previous implementation used FluidAudio's `AudioConverter()`,
        // which on long files would block synchronously inside step 1 for
        // 15+ minutes with no observable progress. The streaming pipeline
        // below resamples in 8s windows, reports fine-grained progress, and
        // honours Task cancellation so the user can bail out.
        await MainActor.run { progress(0.0) }
        let samples: [Float]
        do {
            samples = try await StreamingAudioResampler.resampleToMonoFloat32(
                url: audioURL,
                progress: { fraction in
                    Task { @MainActor in progress(min(0.40, 0.40 * fraction)) }
                }
            )
        } catch is CancellationError {
            throw DiarizationError.http(status: 0, body: "Diarization cancelled by user.")
        } catch StreamingAudioResampler.Error.cancelled {
            throw DiarizationError.http(status: 0, body: "Diarization cancelled by user.")
        } catch {
            await DebugLog.shared.log(icon: "🎭", label: "Resample failed",
                                       value: "\(error)", ok: false)
            throw DiarizationError.audioReadFailed(audioURL)
        }
        await DebugLog.shared.log(icon: "🎭", label: "Resample done",
                                   value: "\(samples.count) samples @ 16kHz")
        await MainActor.run { progress(0.40) }

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
        await MainActor.run { progress(0.55) }

        // 3. Initialize the manager and run.
        let manager = DiarizerManager(config: .default)
        manager.initialize(models: consume models)
        await MainActor.run { progress(0.60) }

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
