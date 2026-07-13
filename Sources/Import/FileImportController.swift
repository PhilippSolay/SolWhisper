import Foundation
import AppKit

/// Orchestrates file import: validate → create meeting folder → copy audio
/// → transcribe → write transcript.json + transcript.md → mark active.
///
/// Progress and final status are surfaced via the `delegate` so the UI layer
/// (the AppDelegate-owned progress window) can remain decoupled from this
/// controller. One controller instance is created per import operation and
/// thrown away on completion.
@MainActor
final class FileImportController {

    enum Phase: Equatable {
        case validating
        case copying
        case loadingModel(modelName: String, alreadyDownloaded: Bool)
        /// Model is loaded but WhisperKit hasn't emitted progress yet.
        /// Covers CoreML warmup + audio preprocessing + first-chunk decode.
        case warming(audioSeconds: Double)
        case transcribing(progress: Double, audioSeconds: Double)
        /// Shared post-processing stages (`MeetingPostProcessor`), each gated by
        /// the same `meetingsAuto*` toggles recordings use. Disabled stages
        /// simply never fire.
        case cleaning
        case diarizing
        case summarizing
        case sending
        case cancelling
        case done(meetingID: UUID, folderURL: URL, segmentCount: Int, audioSeconds: Double)
        case failed(message: String)
    }

    weak var delegate: FileImportControllerDelegate?

    private let store: MeetingStore
    private let model: String
    private var task: Task<Void, Never>?
    private var inFlightMeeting: Meeting?
    private var didCancel = false

    init(store: MeetingStore,
         model: String = FileImportController.configuredModel) {
        self.store = store
        self.model = model
    }

    /// Same WhisperKit model recordings use (Settings → Models → STT Meetings),
    /// so imported and recorded transcripts come out of the same engine.
    /// `nonisolated` so it can be used as an `init` default argument.
    nonisolated static var configuredModel: String {
        UserDefaults.standard.string(forKey: "meetingsWhisperKitModel")
            ?? WhisperKitClient.defaultModel
    }

    /// Begins the import. Cancellable via `cancel()`.
    func begin(audioURL: URL) {
        task = Task { [weak self] in
            await self?.run(audioURL: audioURL)
        }
    }

    /// Signals the in-flight task and removes the half-imported meeting folder.
    /// Idempotent — safe to call multiple times.
    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        update(.cancelling)
        task?.cancel()
        task = nil

        // Clean up the partial meeting folder (audio copied, no transcript) so
        // the user doesn't accumulate orphans on repeated cancels.
        if let meeting = inFlightMeeting {
            inFlightMeeting = nil
            try? store.delete(meeting)
        }
    }

    // MARK: - Pipeline

    private func run(audioURL: URL) async {
        do {
            // 1. Validate
            update(.validating)
            try FileTranscriber.validate(audioURL)
            try Task.checkCancellation()

            // 2. Create meeting folder
            update(.copying)
            let slug = MeetingStore.normalizeSlug(audioURL.deletingPathExtension().lastPathComponent)
            var meeting = try store.create(
                source: .import,
                title: humanTitle(from: audioURL),
                transcriptionBackend: backendIdentifier(),
                folderSlug: slug
            )
            inFlightMeeting = meeting
            store.appendSessionLog(meeting,
                                   "Import started — source=\(audioURL.lastPathComponent)")

            // 3. Copy audio into the meeting folder, preserving extension
            let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension.lowercased()
            let destAudioURL = store.audioURL(for: meeting, ext: ext)
            do {
                if FileManager.default.fileExists(atPath: destAudioURL.path) {
                    try FileManager.default.removeItem(at: destAudioURL)
                }
                try FileManager.default.copyItem(at: audioURL, to: destAudioURL)
            } catch {
                store.appendSessionLog(meeting, "Audio copy failed: \(error)")
                throw error
            }

            // 4. Stamp duration onto the meeting
            let duration = FileTranscriber.durationSeconds(destAudioURL)
            meeting.durationSeconds = duration
            try store.update(meeting)
            try Task.checkCancellation()

            // 5. Load model (separate phase so the UI can tell users they may
            // be waiting on a one-time model download, 139 MB–1.5 GB).
            let modelDownloaded = WhisperKitClient.isModelDownloaded(model)
            update(.loadingModel(modelName: model, alreadyDownloaded: modelDownloaded))

            // 6. Transcribe — start in `.warming` until WhisperKit emits first
            // non-zero progress. WhisperKit's first chunk takes 20–40s for
            // most files (CoreML warmup + audio preload + first decode), and
            // showing a flat "0%" bar during that window looks like a hang.
            update(.warming(audioSeconds: duration))
            let result = try await FileTranscriber.transcribe(
                audioURL: destAudioURL,
                meetingID: meeting.id,
                model: model,
                progress: { [weak self] fraction in
                    guard let self = self else { return }
                    if fraction > 0 {
                        self.update(.transcribing(progress: fraction, audioSeconds: duration))
                    }
                }
            )
            try Task.checkCancellation()

            // 6. Full shared pipeline: clean → write → diarize → summarize →
            //    send, gated by the same meetingsAuto* toggles recordings use.
            //    No `finalizeMeeting` hook — duration is already stamped above
            //    and imports never calendar-link (their timestamp is "now").
            let processed = await MeetingPostProcessor.run(
                meeting: meeting,
                segments: result.document.segments,
                diarizationAudioURL: destAudioURL,
                store: store,
                setPhase: { [weak self] phase in self?.forward(phase) }
            )
            try Task.checkCancellation()

            // The meeting folder can be deleted out from under us during
            // processing; the processor signals that via `completed == false`.
            // Nothing was written, so surface it and let the queue move on.
            guard processed.completed else {
                inFlightMeeting = nil
                update(.failed(message: "Import interrupted"))
                return
            }

            store.appendSessionLog(meeting,
                                   "Import complete — \(processed.segments.count) segments, \(Int(duration))s audio")

            // 7. Done
            inFlightMeeting = nil
            let folder = store.folderURL(for: meeting)
            update(.done(meetingID: meeting.id,
                         folderURL: folder,
                         segmentCount: processed.segments.count,
                         audioSeconds: duration))

            DebugLog.shared.log(icon: "📥", label: "Import done",
                                value: "\(audioURL.lastPathComponent) → \(meeting.folderName)")
        } catch is CancellationError {
            // cancel() already updated UI to .cancelling and trashed the meeting
            DebugLog.shared.log(icon: "📥", label: "Import cancelled",
                                value: audioURL.lastPathComponent)
            update(.failed(message: "Cancelled"))
        } catch {
            DebugLog.shared.log(icon: "📥", label: "Import failed",
                                value: "\(error)", ok: false)
            // If we created a folder before failing, drop it.
            if let m = inFlightMeeting {
                inFlightMeeting = nil
                try? store.delete(m)
            }
            update(.failed(message: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }

    // MARK: - Helpers

    private func update(_ phase: Phase) {
        delegate?.fileImport(self, didEnter: phase)
    }

    /// Maps the shared post-processor's phases onto our import phases so the
    /// queue's step tracker advances Clean → Diarize → Summarize → Send.
    private func forward(_ phase: MeetingProcessingPhase) {
        switch phase {
        case .cleaning:    update(.cleaning)
        case .diarizing:   update(.diarizing)
        case .summarizing: update(.summarizing)
        case .integrating: update(.sending)
        case .stitching, .transcribing:
            break  // imports own these stages themselves
        }
    }

    /// Friendly title for the meeting card. Strips extension, replaces
    /// underscores/hyphens with spaces, title-cases short words for legibility.
    private func humanTitle(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let normalized = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? "Imported audio" : normalized
    }

    /// Identifier for `transcriptionBackend` field. Imports always use WhisperKit
    /// in v0.4 — Apple Speech is microphone-only, Deepgram is streaming-only.
    private func backendIdentifier() -> String {
        return "whisperkit-\(model)"
    }
}

@MainActor
protocol FileImportControllerDelegate: AnyObject {
    func fileImport(_ controller: FileImportController,
                    didEnter phase: FileImportController.Phase)
}
