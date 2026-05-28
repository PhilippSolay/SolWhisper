import Foundation

/// Looks at the user's `diarizationEngine` UserDefault and returns the
/// matching engine instance, or nil when the user has diarization off
/// (or hasn't configured an API key for the picked cloud engine).
@MainActor
enum DiarizationResolver {

    /// All engines registered with the system. Source of truth for the
    /// Settings picker + manual diarize button.
    static let allProviders: [(id: String, label: String, kind: Kind)] = [
        ("assemblyai", "AssemblyAI",    .cloud(needsAPIKey: true)),
        ("deepgram",   "Deepgram",      .cloud(needsAPIKey: true)),
        ("fluidaudio", "FluidAudio (local)", .local(installed: false))
    ]

    enum Kind {
        case cloud(needsAPIKey: Bool)
        case local(installed: Bool)
    }

    static func resolve() -> DiarizationEngine? {
        let raw = UserDefaults.standard.string(forKey: "diarizationEngine") ?? ""
        return engine(forID: raw)
    }

    static func engine(forID id: String) -> DiarizationEngine? {
        switch id {
        case "assemblyai": return AssemblyAIDiarizer()
        case "deepgram":   return DeepgramDiarizer()
        case "fluidaudio": return FluidAudioDiarizer()
        default:           return nil
        }
    }

    /// Pretty label for an engine id (used in audit footers + Debug log).
    static func label(forID id: String) -> String {
        allProviders.first(where: { $0.id == id })?.label ?? id
    }
}

// MARK: - End-to-end "diarize this meeting" runner

@MainActor
enum DiarizationRunner {

    enum Outcome {
        case success(taggedSegments: Int, totalSegments: Int, engineID: String)
        case noEngine
        case failed(String)
        /// User (or caller) cancelled the in-flight run via `Task.cancel()`.
        /// Surfaces separately from `.failed` so the UI can show a friendly
        /// "Diarization cancelled." message instead of a generic error.
        case cancelled
    }

    /// Diarizes the meeting's audio, maps speaker letters onto its
    /// existing `TranscriptSegment`s, and persists the updated transcript
    /// + meeting metadata. `progress` fires 0...1.
    static func run(meeting: Meeting,
                    transcript: TranscriptDocument,
                    audioURL: URL,
                    store: MeetingStore,
                    engineID: String? = nil,
                    progress: @MainActor @escaping (Double) -> Void) async -> Outcome {

        let resolved: DiarizationEngine?
        let resolvedID: String
        if let forced = engineID, let e = DiarizationResolver.engine(forID: forced) {
            resolved = e
            resolvedID = forced
        } else if let e = DiarizationResolver.resolve() {
            resolved = e
            resolvedID = UserDefaults.standard.string(forKey: "diarizationEngine") ?? "—"
        } else {
            return .noEngine
        }
        guard let engine = resolved else { return .noEngine }

        do {
            try Task.checkCancellation()
            let speakerSegs = try await engine.diarize(audioURL: audioURL,
                                                        progress: progress)
            try Task.checkCancellation()
            DebugLog.shared.log(icon: "🎭", label: "Diarization",
                                value: "\(resolvedID) returned \(speakerSegs.count) speaker segments")

            let tagged = DiarizationMapper.apply(speakerSegs, to: transcript.segments)
            let taggedCount = tagged.filter { $0.speakerID != nil }.count

            // Persist updated transcript.
            let updatedDoc = TranscriptDocument(meetingID: meeting.id, segments: tagged)
            try store.writeTranscript(updatedDoc, for: meeting)

            // Stamp audit on the meeting.
            var updated = meeting
            updated.diarizationEngine = resolvedID
            // Preserve any existing speakerNames; they remain valid as
            // long as the engine returns the same speaker letters.
            updated.updatedAt = Date()
            try? store.update(updated)

            // Voice matcher pass — for any saved profile with an
            // embedding, see if a detected speaker matches and auto-fill
            // the name. Macros 14+ only; cheap no-op otherwise.
            if #available(macOS 14.0, *) {
                let matches = await VoiceMatcher.match(
                    meeting: updated,
                    transcript: updatedDoc,
                    audioURL: audioURL,
                    store: store,
                    profileStore: VoiceProfileStore.shared
                )
                if !matches.isEmpty {
                    DebugLog.shared.log(icon: "🎯", label: "Auto-named speakers",
                                        value: "\(matches.count) match(es)")
                }
            }

            return .success(taggedSegments: taggedCount,
                            totalSegments: tagged.count,
                            engineID: resolvedID)
        } catch is CancellationError {
            DebugLog.shared.log(icon: "🎭", label: "Diarization cancelled",
                                value: "user cancelled in-flight run")
            return .cancelled
        } catch StreamingAudioResampler.Error.cancelled {
            DebugLog.shared.log(icon: "🎭", label: "Diarization cancelled",
                                value: "resampler cancelled")
            return .cancelled
        } catch {
            // FluidAudio bridges resampler cancellation as a synthetic HTTP
            // error with status 0 and a known body — recognize that too so
            // the UI can render a clean "cancelled" message rather than
            // "Diarization cancelled by user." as a generic failure.
            if Task.isCancelled {
                DebugLog.shared.log(icon: "🎭", label: "Diarization cancelled",
                                    value: "task cancelled (\(error.localizedDescription))")
                return .cancelled
            }
            DebugLog.shared.log(icon: "🎭", label: "Diarization failed",
                                value: error.localizedDescription, ok: false)
            return .failed(error.localizedDescription)
        }
    }
}
