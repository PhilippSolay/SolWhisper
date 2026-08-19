import Foundation

/// Shared post-transcription pipeline: clean → write → diarize → summarize →
/// integrate. Each stage is gated by the same `meetingsAuto*` toggles the
/// live-recording flow uses, so recordings and file imports produce identical
/// output and can never drift.
///
/// The caller owns everything BEFORE this runs — producing transcribed +
/// sorted `segments`, stamping duration, and (recordings only) calendar
/// auto-linking. `diarizationAudioURL` is the combined `audio.m4a` for
/// recordings and the imported file for imports. Stage transitions are
/// reported through `setPhase` so each caller can route them to its own
/// progress sink (the menu-bar pipeline indicator, or the import queue).
@MainActor
enum MeetingPostProcessor {

    struct Result {
        /// Final segments (post-diarize when diarization ran).
        var segments: [TranscriptSegment]
        /// Summary markdown, or "" when summarization was skipped or failed.
        var summaryMarkdown: String
        /// False when the run bailed at a checkpoint (meeting deleted or
        /// cancelled mid-processing) before writing outputs.
        var completed: Bool
    }

    // MARK: - Stage gating

    /// Whether each optional stage is enabled, read from the shared
    /// `meetingsAuto*` toggles. `run` gates on these (plus runtime conditions
    /// like non-empty segments / a resolvable LLM); the import queue uses
    /// `enabledStages()` to render disabled stages as "skipped" in its tracker.
    /// Single source of truth so the two never drift.
    static var autoCleanEnabled: Bool {
        (UserDefaults.standard.object(forKey: "meetingsAutoCleanTranscript") as? Bool) ?? true
    }
    static var autoDiarizeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "meetingsAutoDiarize")
            && !(UserDefaults.standard.string(forKey: "diarizationEngine") ?? "").isEmpty
    }
    static var autoSummarizeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "meetingsAutoSummarize")
    }
    static var autoIntegrateEnabled: Bool {
        UserDefaults.standard.bool(forKey: "meetingsAutoIntegrate")
    }

    /// Filename of the post-processing completion marker, written at the very
    /// END of a successful `run` (after summary/diarize/integrate). Its presence
    /// means every enabled post-transcript stage finished; its ABSENCE while
    /// `transcript.json` exists means the run was interrupted mid-post-processing
    /// (crash/force-quit after the transcript write but before the run finished).
    /// `CrashRecovery.incompletePostProcessing(in:)` keys off exactly that gap.
    /// Deliberately distinct from `transcript.json`, which recovery treats as the
    /// "already transcribed — don't re-transcribe" signal.
    static let completionMarkerFilename = "postprocessed.flag"

    /// Stages that will be attempted for a fresh run (transcribe always; the
    /// rest per toggle). Used by the import queue's step tracker.
    static func enabledStages() -> Set<MeetingProcessingPhase> {
        var stages: Set<MeetingProcessingPhase> = [.transcribing]
        if autoCleanEnabled { stages.insert(.cleaning) }
        if autoDiarizeEnabled { stages.insert(.diarizing) }
        if autoSummarizeEnabled { stages.insert(.summarizing) }
        if autoIntegrateEnabled { stages.insert(.integrating) }
        return stages
    }

    /// - Parameter finalizeMeeting: Runs once the meeting folder is confirmed
    ///   to still exist (after clean, before any writes) so metadata updates
    ///   can't resurrect a meeting the user deleted mid-processing. Recordings
    ///   use it to stamp duration + calendar auto-link; imports pass nil. The
    ///   returned meeting is used for all subsequent stages.
    static func run(
        meeting: Meeting,
        segments: [TranscriptSegment],
        diarizationAudioURL: URL,
        store: MeetingStore,
        setPhase: @MainActor (MeetingProcessingPhase) -> Void,
        finalizeMeeting: (@MainActor (Meeting) async -> Meeting)? = nil
    ) async -> Result {
        var meeting = meeting
        var allSegments = segments

        // 1. Optional LLM cleanup — on by default (Settings → STT Meetings).
        //    Reuses the dictation polish-rule toggles so there's one rule set
        //    across both modes.
        if autoCleanEnabled, !allSegments.isEmpty, let resolved = LLMResolver.resolve(.cleanup) {
            setPhase(.cleaning)
            let cleanStart = Date()
            let pass = CleanupPass(client: resolved.client, model: resolved.modelID)
            do {
                allSegments = try await pass.clean(allSegments, forceAllRulesIfEmpty: true)
                logElapsed("Auto-clean", since: cleanStart, detail: "\(allSegments.count) segments")
            } catch {
                DebugLog.shared.log(icon: "🧹", label: "Auto-clean failed",
                                    value: error.localizedDescription, ok: false)
                // Keep raw segments on failure — the meeting still ships.
            }
        }

        // Checkpoint before persisting: if the meeting was deleted or the run
        // cancelled mid-clean, bail now — otherwise the writes below re-create
        // the trashed folder and resurrect a zombie meeting.
        if Task.isCancelled || !folderExists(meeting, store: store) {
            DebugLog.shared.log(icon: "🗑", label: "Meeting removed mid-processing — skipping writes",
                                value: meeting.folderName)
            return Result(segments: allSegments, summaryMarkdown: "", completed: false)
        }

        // 1b. Folder confirmed present — let the caller finalize meeting
        //     metadata (duration, calendar) before we persist anything.
        if let finalizeMeeting {
            meeting = await finalizeMeeting(meeting)
            // finalizeMeeting can suspend (calendar/permission checks); re-check
            // so a meeting deleted during it isn't resurrected by the writes below.
            if Task.isCancelled || !folderExists(meeting, store: store) {
                DebugLog.shared.log(icon: "🗑", label: "Meeting removed during finalize — skipping writes",
                                    value: meeting.folderName)
                return Result(segments: allSegments, summaryMarkdown: "", completed: false)
            }
        }

        // 2. Persist transcript.json + transcript.md.
        let document = TranscriptDocument(meetingID: meeting.id, segments: allSegments)
        do {
            try store.writeTranscript(document, for: meeting)
            let md = TranscriptMarkdown.render(document, title: meeting.title, includeSpeakers: true)
            try store.writeTranscriptMarkdown(md, for: meeting)
        } catch {
            DebugLog.shared.log(icon: "📝", label: "Transcript write failed",
                                value: "\(error)", ok: false)
        }

        // 3. Optional auto-diarization. Runs on the supplied audio (combined
        //    mic+system stream for recordings, the imported file for imports).
        if autoDiarizeEnabled, !allSegments.isEmpty {
            setPhase(.diarizing)
            let diarizeStart = Date()
            let docCopy = TranscriptDocument(meetingID: meeting.id, segments: allSegments)
            let outcome = await DiarizationRunner.run(
                meeting: meeting,
                transcript: docCopy,
                audioURL: diarizationAudioURL,
                store: store,
                progress: { _ in }
            )
            if case .success(let tagged, let total, let engineID) = outcome {
                logElapsed("Auto-diarize", since: diarizeStart,
                           detail: "\(tagged)/\(total) tagged via \(engineID)")
                // Reload from disk to pick up the persisted speakerID assignments.
                if let reloaded = try? store.loadTranscript(for: meeting) {
                    allSegments = reloaded.segments
                    let md = TranscriptMarkdown.render(reloaded, title: meeting.title, includeSpeakers: true)
                    try? store.writeTranscriptMarkdown(md, for: meeting)
                }
            } else if case .failed(let msg) = outcome {
                DebugLog.shared.log(icon: "🎭", label: "Auto-diarize failed",
                                    value: msg, ok: false)
            }
        }

        // 4. Optional auto-summarize.
        var summaryMarkdown = ""
        if autoSummarizeEnabled, !allSegments.isEmpty {
            setPhase(.summarizing)
            let summaryStart = Date()
            summaryMarkdown = await runSummary(meeting: meeting, segments: allSegments, store: store)
            logElapsed("Auto-summarize", since: summaryStart, detail: "\(summaryMarkdown.count) chars")
        }

        // 5. Optional integrations fan-out. Sends the transcript markdown built
        //    from `document` (matching the live-recording behavior) plus the
        //    summary; failures inside the fanout log but never throw.
        if autoIntegrateEnabled {
            setPhase(.integrating)
            let integrateStart = Date()
            let transcriptMD = TranscriptMarkdown.render(document, title: meeting.title, includeSpeakers: true)
            _ = await IntegrationFanout.send(
                meeting: meeting,
                transcriptMarkdown: transcriptMD,
                summaryMarkdown: summaryMarkdown,
                audioFileURL: store.audioFileURL(for: meeting)
            )
            logElapsed("Integrations fan-out", since: integrateStart)
        }

        store.appendSessionLog(meeting,
                               "Meeting processing complete — \(allSegments.count) segments")

        // Completion marker — written last, so its presence proves every enabled
        // post-transcript stage ran. A crash between the transcript write (step 2)
        // and here leaves transcript.json without this marker, which is what lets
        // CrashRecovery detect (and, once wired, resume) the dropped stages.
        writeCompletionMarker(for: meeting, store: store)

        return Result(segments: allSegments, summaryMarkdown: summaryMarkdown, completed: true)
    }

    // MARK: - Summary

    /// Picks the configured skill + LLM, runs the summary, persists it.
    /// Returns the summary markdown (or an empty string on failure).
    private static func runSummary(meeting: Meeting,
                                   segments: [TranscriptSegment],
                                   store: MeetingStore) async -> String {
        let skillID = UserDefaults.standard.string(forKey: "meetingsDefaultSkillID") ?? "meeting-summary"
        let registry = SkillsRegistry.shared

        guard let resolved = LLMResolver.resolve(.summary) else {
            DebugLog.shared.log(icon: "📝", label: "Summary skipped",
                                value: "no LLM routing resolved", ok: false)
            return ""
        }
        let generator = SummaryGenerator(client: resolved.client,
                                         provider: resolved.providerLabel,
                                         model: resolved.modelID)

        // Prefer the SkillPack path with auto-classify when the configured
        // skill matches a loaded pack. Falls back to the flat-skill path for
        // legacy built-ins (sales-call, standup, etc.).
        if let pack = registry.skillPacks.first(where: { $0.id == skillID })
            ?? registry.meetingSummaryPack {
            do {
                let summary = try await generator.generate(meeting: meeting,
                                                           segments: segments,
                                                           pack: pack,
                                                           meetingType: nil)
                try store.writeSummary(summary, for: meeting)
                DebugLog.shared.log(icon: "📝", label: "Summary written",
                                    value: "pack=\(pack.id) type=\(summary.meetingType ?? "?") model=\(summary.llmModel)")
                return summary.rawMarkdown
            } catch {
                DebugLog.shared.log(icon: "📝", label: "Summary failed",
                                    value: "\(error)", ok: false)
                return ""
            }
        }

        let skill = registry.skill(withID: skillID) ?? registry.defaultSkill
        do {
            let summary = try await generator.generate(meeting: meeting,
                                                       segments: segments,
                                                       skill: skill)
            try store.writeSummary(summary, for: meeting)
            DebugLog.shared.log(icon: "📝", label: "Summary written",
                                value: "skill=\(skill.id) model=\(summary.llmModel)")
            return summary.rawMarkdown
        } catch {
            DebugLog.shared.log(icon: "📝", label: "Summary failed",
                                value: "\(error)", ok: false)
            return ""
        }
    }

    // MARK: - Helpers

    /// Writes the empty completion marker into the meeting folder. Best-effort:
    /// a failure here is non-fatal (the meeting is fully processed either way).
    /// A missing marker only makes recovery re-offer post-processing, which is
    /// safe to skip — far better than throwing at the finish line.
    private static func writeCompletionMarker(for meeting: Meeting, store: MeetingStore) {
        let url = store.folderURL(for: meeting)
            .appendingPathComponent(completionMarkerFilename)
        do {
            try Data().write(to: url)
        } catch {
            DebugLog.shared.log(icon: "🏁", label: "Completion marker write failed",
                                value: "\(error)", ok: false)
        }
    }

    private static func folderExists(_ meeting: Meeting, store: MeetingStore) -> Bool {
        FileManager.default.fileExists(atPath: store.folderURL(for: meeting).path)
    }

    private static func logElapsed(_ name: String, since: Date, detail: String? = nil) {
        let elapsed = MeetingController.elapsedString(since: since)
        let value = detail.map { "\($0) · \(elapsed)" } ?? elapsed
        DebugLog.shared.log(icon: "⏱", label: "\(name) done", value: value)
    }
}
