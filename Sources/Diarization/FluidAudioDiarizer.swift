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

    /// Static helper used by `VoiceProfileEmbedder` and `VoiceMatcher` to
    /// extract a single embedding from a slice of audio. Reuses a cached
    /// `DiarizerManager` across calls so the model-compile cost (heavy on
    /// CoreML) only happens once per app session, not per profile/letter.
    /// Without this cache, backfilling N profiles meant N cold model loads
    /// — roughly N × 1.5s of pure overhead.
    @available(macOS 14.0, *)
    static func extractEmbedding(samples: [Float]) async throws -> [Float] {
        let manager = try await EmbedderCache.sharedManager()
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    /// Process-wide singleton holding the loaded FluidAudio diarizer.
    /// Constructed on first use, then reused for every subsequent
    /// `extractEmbedding` call. Concurrent first-use is serialized by the
    /// actor so we never double-download or double-compile.
    @available(macOS 14.0, *)
    actor EmbedderCache {
        static let shared = EmbedderCache()
        private var manager: DiarizerManager?

        static func sharedManager() async throws -> DiarizerManager {
            try await shared.get()
        }

        private func get() async throws -> DiarizerManager {
            if let manager { return manager }
            let models = try await DiarizerModels.downloadIfNeeded()
            let m = DiarizerManager(config: .default)
            m.initialize(models: consume models)
            self.manager = m
            return m
        }

        /// Drops the cached manager. Useful for tests and for recovering
        /// from a corrupted model load. The next call rebuilds it.
        func reset() { manager = nil }
    }
    #endif
}
