import Foundation
import AVFoundation
import AppKit

/// Single-instance state machine for meeting recording.
///
/// Owns: `MeetingAudioEngine` + `ChunkWriter` + post-stop pipeline.
/// Does NOT own: settings, meeting store (those are MainActor singletons
/// passed in). Per the plan: "single-instance, owned by AppDelegate. Not
/// singleton."
///
/// State transitions (per Sources/Meeting/ConcurrencyDesign.md §6):
///
///   idle → starting → recording → paused → recording
///                                       ↘ stopping → processing → idle
///
/// Stopping/processing always end at `.idle`. Errors at any step end at
/// `.idle` after surfacing a debug log entry.
@MainActor
final class MeetingController: ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case recording(meetingID: UUID)
        case paused(meetingID: UUID)
        case stopping(meetingID: UUID)
        case processing(meetingID: UUID)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var isClipping: Bool = false
    @Published private(set) var spectrumBins: [Float] = [Float](repeating: 0, count: AudioEngine.fftBinCount)
    @Published private(set) var deviceHealth: DeviceMonitor.Health = .healthy(deviceName: "Built-in")

    /// Which post-processing phase is currently running for which meeting.
    /// Drives the multi-step pipeline indicator in the meeting detail view
    /// and the AppDelegate's "open transcripts window when post-processing
    /// kicks off" handoff. Nil between recordings.
    @Published private(set) var processingPhase: MeetingProcessingPhase? = nil
    @Published private(set) var processingMeetingID: UUID? = nil

    /// Fires when post-processing transitions from idle → stitching (first
    /// real work after recording stops). AppDelegate uses this to swap the
    /// pill for the Transcripts window with the new meeting selected.
    var onProcessingStarted: ((UUID) -> Void)?

    /// Fraction (0...1) of the mic-channel transcribe pass during
    /// post-processing. Nil when transcribe isn't running. The pipeline
    /// indicator averages this with `transcribeSystemProgress` to show a
    /// single moving bar during the transcribe phase.
    @Published private(set) var transcribeMicProgress: Double? = nil
    /// Same for the system-audio channel.
    @Published private(set) var transcribeSystemProgress: Double? = nil

    /// Combined 0…1 transcribe progress (50/50 weighted average of mic +
    /// system) used by the pipeline indicator. Nil when neither channel is
    /// actively reporting.
    var transcribeProgress: Double? {
        switch (transcribeMicProgress, transcribeSystemProgress) {
        case (nil, nil): return nil
        case (let m?, nil): return m
        case (nil, let s?): return s
        case (let m?, let s?): return (m + s) / 2
        }
    }

    var isRecording: Bool {
        switch state {
        case .recording, .paused: return true
        default: return false
        }
    }

    var onProcessed: ((UUID) -> Void)?

    private let store: MeetingStore
    private var engine: MeetingAudioEngine?
    private var writer: ChunkWriter?
    private var meeting: Meeting?
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private let clippingDetector = ClippingDetector()
    private let deviceMonitor = DeviceMonitor()
    private var deviceHealthTask: Task<Void, Never>?

    init(store: MeetingStore) {
        self.store = store
    }

    /// Honors the user's pick from Settings → Models → STT Meetings.
    private var meetingsWhisperKitModel: String {
        UserDefaults.standard.string(forKey: "meetingsWhisperKitModel")
            ?? WhisperKitClient.defaultModel
    }

    // MARK: - Public API

    /// Triggered by the tray "Record meeting" item.
    func start() {
        Task { @MainActor in await self.startInternal() }
    }

    /// Triggered by the tray "Pause meeting" item.
    func pause() {
        guard case .recording(let id) = state else { return }
        engine?.isPaused = true
        state = .paused(meetingID: id)
        DebugLog.shared.log(icon: "⏸", label: "Meeting paused")
    }

    /// Triggered by the tray "Resume meeting" item.
    func resume() {
        guard case .paused(let id) = state else { return }
        engine?.isPaused = false
        state = .recording(meetingID: id)
        DebugLog.shared.log(icon: "▶️", label: "Meeting resumed")
    }

    /// Triggered by the tray "Stop meeting" item.
    func stop() {
        Task { @MainActor in await self.stopInternal() }
    }

    /// Cancels everything in flight. Discards the meeting folder. Used when
    /// the user wants to throw away an in-progress recording.
    func cancel() {
        Task { @MainActor in await self.cancelInternal() }
    }

    // MARK: - Pipeline

    private func startInternal() async {
        guard case .idle = state else { return }
        state = .starting

        // Sprint 8 — first-time consent disclaimer.
        guard PrivacyDisclaimer.ensureAccepted() else {
            DebugLog.shared.log(icon: "🛡", label: "Meeting cancelled — disclaimer declined")
            state = .idle
            return
        }

        // Permission check up front so the user gets a single prompt rather
        // than a half-started session.
        let hasMic = await requestMicPermission()
        guard hasMic else {
            DebugLog.shared.log(icon: "🎙", label: "Meeting blocked",
                                value: "microphone not authorized", ok: false)
            state = .idle
            return
        }
        let hasScreen = await SystemAudioCapture.ensurePermission()
        if !hasScreen {
            DebugLog.shared.log(icon: "🔉", label: "Screen recording not granted",
                                value: "system audio will be silent", ok: false)
            // Continue — mic-only recording is still useful.
        }

        // Create the meeting folder.
        let slug = "meeting-\(MeetingController.timeSlug(Date()))"
        let meeting: Meeting
        do {
            meeting = try store.create(
                source: .recording,
                title: "Meeting \(MeetingController.humanTimeStamp(Date()))",
                transcriptionBackend: "whisperkit-\(meetingsWhisperKitModel)",
                folderSlug: slug
            )
        } catch {
            DebugLog.shared.log(icon: "🎙", label: "Meeting create failed",
                                value: "\(error)", ok: false)
            state = .idle
            return
        }
        self.meeting = meeting

        let engine = MeetingAudioEngine()
        engine.capturesSystemAudio = hasScreen
        self.engine = engine

        // The mic format is decided when the engine starts; system format is
        // a fixed 48 kHz stereo float per SystemAudioCapture's spec. We can't
        // initialize ChunkWriter until mic format is known, so we wire a thin
        // callback that defers writes until we have it.
        var pendingMic: [AVAudioPCMBuffer] = []
        var pendingSystem: [AVAudioPCMBuffer] = []
        var resolvedMicFormat: AVAudioFormat?

        engine.onMicBuffer = { [weak self] buffer in
            guard let self else { return }
            if resolvedMicFormat == nil {
                resolvedMicFormat = buffer.format
                guard let systemFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: SystemAudioCapture.sampleRate,
                    channels: SystemAudioCapture.channelCount,
                    interleaved: false
                ) else {
                    DebugLog.shared.log(icon: "🎬", label: "Bootstrap failed",
                                        value: "couldn't construct system AVAudioFormat",
                                        ok: false)
                    return
                }
                self.bootstrapWriter(meeting: meeting,
                                     micFormat: buffer.format,
                                     systemFormat: systemFormat,
                                     pendingMic: &pendingMic,
                                     pendingSystem: &pendingSystem)
            }
            // Clipping detector observes the mic side (your voice) — that's the
            // only channel where the user can act on the warning.
            if UserDefaults.standard.object(forKey: "meetingsClippingDetect") == nil
                || UserDefaults.standard.bool(forKey: "meetingsClippingDetect") {
                let clipped = self.clippingDetector.observe(buffer)
                self.isClipping = clipped
            }
            if let writer = self.writer {
                Task { await writer.appendMic(buffer) }
            } else {
                pendingMic.append(buffer)
            }
        }
        engine.onSystemBuffer = { [weak self] buffer in
            guard let self, let writer = self.writer else {
                pendingSystem.append(buffer)
                return
            }
            Task { await writer.appendSystem(buffer) }
        }
        engine.onLevels = { [weak self] mic, system in
            self?.micLevel = mic
            self?.systemLevel = system
        }
        engine.onSpectrum = { [weak self] bins in
            self?.spectrumBins = bins
        }

        do {
            try await engine.start()
        } catch {
            DebugLog.shared.log(icon: "🎙", label: "Meeting engine failed to start",
                                value: "\(error)", ok: false)
            state = .idle
            self.engine = nil
            self.meeting = nil
            return
        }

        // Start watching device changes — surface BT warnings + auto-pause on
        // disconnect so the user can switch mics mid-call.
        let pinnedUID = PreferredInputDevice.uid
        let pinnedName = PreferredInputDevice.availableInputs()
            .first(where: { $0.uid == pinnedUID })?.name
        deviceMonitor.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .inputLost(let name):
                DebugLog.shared.log(icon: "🎚", label: "Mic disconnected during meeting",
                                    value: name, ok: false)
                if case .recording = self.state { self.pause() }
            default:
                break
            }
        }
        deviceMonitor.start(currentInputUID: pinnedUID, currentName: pinnedName)
        // Bridge published health onto the controller's @Published mirror.
        // Cancelled in stop/cancel — without this, every meeting leaks one
        // long-running stream consumer.
        deviceHealthTask?.cancel()
        deviceHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await h in self.deviceMonitor.$health.values {
                if Task.isCancelled { return }
                self.deviceHealth = h
            }
        }

        state = .recording(meetingID: meeting.id)
        startedAt = Date()
        elapsed = 0
        startElapsedTimer()
        store.appendSessionLog(meeting, "Meeting recording started")
        DebugLog.shared.log(icon: "🎙", label: "Meeting recording started",
                            value: meeting.folderName)
    }

    private func bootstrapWriter(meeting: Meeting,
                                 micFormat: AVAudioFormat,
                                 systemFormat: AVAudioFormat,
                                 pendingMic: inout [AVAudioPCMBuffer],
                                 pendingSystem: inout [AVAudioPCMBuffer]) {
        let chunksDir = store.folderURL(for: meeting).appendingPathComponent("chunks")
        do {
            let writer = try ChunkWriter(
                chunkDirectory: chunksDir,
                chunkSeconds: 30,
                micFormat: micFormat,
                systemFormat: systemFormat
            )
            self.writer = writer
            for buf in pendingMic { Task { await writer.appendMic(buf) } }
            for buf in pendingSystem { Task { await writer.appendSystem(buf) } }
            pendingMic.removeAll()
            pendingSystem.removeAll()
        } catch {
            DebugLog.shared.log(icon: "🧱", label: "ChunkWriter init failed",
                                value: "\(error)", ok: false)
        }
    }

    private func stopInternal() async {
        guard let meeting else { return }
        let id: UUID
        switch state {
        case .recording(let mid), .paused(let mid): id = mid
        default: return
        }
        state = .stopping(meetingID: id)
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        deviceMonitor.stop()
        deviceHealthTask?.cancel()
        deviceHealthTask = nil

        await engine?.stop()
        engine = nil

        if let writer { await writer.finalize() }

        // Move to processing — stitch chunks, transcribe, write outputs.
        state = .processing(meetingID: meeting.id)
        Task { await self.runPostProcessing(for: meeting) }
    }

    private func cancelInternal() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        deviceMonitor.stop()
        deviceHealthTask?.cancel()
        deviceHealthTask = nil
        await engine?.stop()
        engine = nil
        if let writer { await writer.finalize() }
        if let meeting {
            try? store.delete(meeting)
        }
        state = .idle
        meeting = nil
        DebugLog.shared.log(icon: "🛑", label: "Meeting cancelled — folder discarded")
    }

    // MARK: - Recovery

    /// Picks up a meeting whose chunks/ folder still exists but `done.flag`
    /// is missing (force-quit / crash). Re-runs the full stitch + transcribe
    /// + summarize pipeline. Reuses `runPostProcessing` so behavior matches
    /// a normal stop exactly.
    func recover(orphan meeting: Meeting) {
        guard case .idle = state else {
            DebugLog.shared.log(icon: "🛟", label: "Recovery skipped — controller busy")
            return
        }
        DebugLog.shared.log(icon: "🛟", label: "Recovering orphan",
                            value: meeting.folderName)
        self.meeting = meeting

        // Mark the chunks/ folder finalised so a second crash-recovery scan
        // doesn't re-flag this meeting if processing fails halfway through.
        let chunksDir = store.folderURL(for: meeting).appendingPathComponent("chunks")
        let doneFlag = chunksDir.appendingPathComponent("done.flag")
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: doneFlag, atomically: true, encoding: .utf8)

        state = .processing(meetingID: meeting.id)
        Task { await self.runPostProcessing(for: meeting) }
    }

    // MARK: - Post-processing

    private func runPostProcessing(for meeting: Meeting) async {
        let folder = store.folderURL(for: meeting)
        let chunksDir = folder.appendingPathComponent("chunks")
        let micOutURL = folder.appendingPathComponent("audio_mic.wav")
        let systemOutURL = folder.appendingPathComponent("audio_system.wav")
        let mixedOutURL = folder.appendingPathComponent("audio.wav")
        let pipelineStart = Date()

        processingMeetingID = meeting.id
        setPhase(.stitching, for: meeting)
        onProcessingStarted?(meeting.id)

        // Belt-and-braces cleanup: if any future edit between here and the
        // end of the function escapes via `throw` or `return`, the controller
        // would otherwise be left with phase publishers set forever (the
        // pipeline indicator in the detail view would spin indefinitely).
        // Today every error path catches in-place, but a defer survives
        // refactors. Keep state reset paired with phase reset.
        let completedMeetingID = meeting.id
        defer {
            processingPhase = nil
            processingMeetingID = nil
            if case .idle = state {} else { state = .idle }
            self.meeting = nil
            onProcessed?(completedMeetingID)
        }

        do {
            let stitchStart = Date()
            try await stitchChunks(in: chunksDir, prefix: "mic", to: micOutURL)
            try await stitchChunks(in: chunksDir, prefix: "sys", to: systemOutURL)
            try mixToCombined(mic: micOutURL, system: systemOutURL, output: mixedOutURL)
            // Remove the chunk directory now that we have the stitched files.
            try? FileManager.default.removeItem(at: chunksDir)
            logPhaseElapsed("Stitch", since: stitchStart)
        } catch {
            DebugLog.shared.log(icon: "🎬", label: "Stitch failed",
                                value: "\(error)", ok: false)
            // Don't bail — try transcription on whatever made it to the stitched outputs.
        }

        // Transcribe both channels concurrently. The mic and system audio
        // are independent files; running them in parallel roughly halves
        // wall-clock time when both have content (the ANE is shared so
        // speedup is usually 1.3–1.7x, not a perfect 2x). Channel-level
        // progress fractions are weighted 50/50 and routed into the
        // pipeline indicator via the shared `transcribePhaseProgress`
        // helper below.
        setPhase(.transcribing, for: meeting)
        let transcribeStart = Date()
        let model = meetingsWhisperKitModel
        let micExists = FileManager.default.fileExists(atPath: micOutURL.path)
        let sysExists = FileManager.default.fileExists(atPath: systemOutURL.path)

        async let micResult: [TranscriptSegment] = micExists
            ? Self.transcribeChannel(audioURL: micOutURL,
                                      model: model,
                                      speaker: SpeakerLabel.me,
                                      onProgress: { [weak self] f in
                                          Task { @MainActor in
                                              self?.transcribeMicProgress = f
                                          }
                                      })
            : []
        async let sysResult: [TranscriptSegment] = sysExists
            ? Self.transcribeChannel(audioURL: systemOutURL,
                                      model: model,
                                      speaker: SpeakerLabel.other,
                                      onProgress: { [weak self] f in
                                          Task { @MainActor in
                                              self?.transcribeSystemProgress = f
                                          }
                                      })
            : []

        var allSegments = await micResult + sysResult
        transcribeMicProgress = nil
        transcribeSystemProgress = nil
        logPhaseElapsed("Transcribe", since: transcribeStart,
                        detail: "\(allSegments.count) segments · model=\(model) · parallel=\(micExists && sysExists)")

        // Sort by start time so [Me] / [Other] interleave naturally.
        allSegments.sort(by: { $0.start < $1.start })

        // Optional LLM cleanup — fired after stitch when the user has the
        // Auto-clean toggle on (Settings → STT Meetings). Reuses the
        // dictation-side polish-rule toggles (remove filler / fix punctuation /
        // fix grammar) so there's one set of rules across both modes.
        let autoClean = (UserDefaults.standard.object(forKey: "meetingsAutoCleanTranscript") as? Bool) ?? true
        if autoClean,
           !allSegments.isEmpty,
           let resolved = LLMResolver.resolve(.cleanup) {
            setPhase(.cleaning, for: meeting)
            let cleanStart = Date()
            let pass = CleanupPass(client: resolved.client, model: resolved.modelID)
            do {
                allSegments = try await pass.clean(allSegments, forceAllRulesIfEmpty: true)
                logPhaseElapsed("Auto-clean", since: cleanStart,
                                detail: "\(allSegments.count) segments")
            } catch {
                DebugLog.shared.log(icon: "🧹", label: "Auto-clean failed",
                                    value: error.localizedDescription, ok: false)
                // Keep raw segments on failure — meeting still ships.
            }
        }

        let document = TranscriptDocument(meetingID: meeting.id, segments: allSegments)
        do {
            try store.writeTranscript(document, for: meeting)
            let md = renderMarkdown(document, title: meeting.title)
            try store.writeTranscriptMarkdown(md, for: meeting)
        } catch {
            DebugLog.shared.log(icon: "📝", label: "Transcript write failed",
                                value: "\(error)", ok: false)
        }

        // Stamp duration onto the meeting (mic file length is canonical).
        var updated = meeting
        updated.durationSeconds = audioDurationSeconds(micOutURL) ?? 0
        try? store.update(updated)

        // Auto-link calendar event — if no event is linked yet and the
        // best-match has reasonable confidence, attach it now so the user
        // (and the summary prompt) immediately see the event title and
        // attendee list. The match is purely time-overlap based — see
        // CalendarIntegration.bestMatch.
        if updated.calendarEventID == nil {
            updated = await autoLinkCalendarEvent(meeting: updated)
        }

        // Optional auto-diarization. Runs on the COMBINED audio (mixed
        // mic+system stream) so we get speaker letters that include both
        // sides of the call. Replaces the channel-based [Me]/[Other] tags
        // visually but keeps them in the model for back-compat.
        let autoDiarize = UserDefaults.standard.bool(forKey: "meetingsAutoDiarize")
        let engineConfigured = !(UserDefaults.standard.string(forKey: "diarizationEngine") ?? "").isEmpty
        if autoDiarize, engineConfigured, !allSegments.isEmpty {
            setPhase(.diarizing, for: meeting)
            let diarizeStart = Date()
            let combinedURL = store.audioURL(for: meeting, ext: "wav")
            let docCopy = TranscriptDocument(meetingID: meeting.id, segments: allSegments)
            let outcome = await DiarizationRunner.run(
                meeting: updated,
                transcript: docCopy,
                audioURL: combinedURL,
                store: store,
                progress: { _ in }
            )
            if case .success(let tagged, let total, let engineID) = outcome {
                logPhaseElapsed("Auto-diarize", since: diarizeStart,
                                detail: "\(tagged)/\(total) tagged via \(engineID)")
                // Reload from disk to get the persisted speakerID assignments.
                if let reloaded = try? store.loadTranscript(for: updated) {
                    allSegments = reloaded.segments
                    let md = renderMarkdown(reloaded, title: updated.title)
                    try? store.writeTranscriptMarkdown(md, for: updated)
                }
            } else if case .failed(let msg) = outcome {
                DebugLog.shared.log(icon: "🎭", label: "Auto-diarize failed",
                                    value: msg, ok: false)
            }
        }

        // Sprint 5 — optional auto-summarize. Off by default — the user can
        // also trigger summarize from the Transcripts UI later (Sprint 5 polish).
        var summaryMarkdown = ""
        if UserDefaults.standard.bool(forKey: "meetingsAutoSummarize"),
           !allSegments.isEmpty {
            setPhase(.summarizing, for: meeting)
            let summaryStart = Date()
            summaryMarkdown = await runSummary(meeting: updated, segments: allSegments)
            logPhaseElapsed("Auto-summarize", since: summaryStart,
                            detail: "\(summaryMarkdown.count) chars")
        }

        // Sprint 6 — optional integrations fan-out.
        if UserDefaults.standard.bool(forKey: "meetingsAutoIntegrate") {
            setPhase(.integrating, for: meeting)
            let integrateStart = Date()
            let transcriptMD = renderMarkdown(document, title: updated.title)
            await fanOutToIntegrations(meeting: updated,
                                        transcriptMarkdown: transcriptMD,
                                        summaryMarkdown: summaryMarkdown)
            logPhaseElapsed("Integrations fan-out", since: integrateStart)
        }

        store.appendSessionLog(updated,
                               "Meeting processing complete — \(allSegments.count) segments")

        DebugLog.shared.log(icon: "🎬", label: "Meeting processing done",
                            value: "\(meeting.folderName) · \(allSegments.count) segments · total \(Self.elapsedString(since: pipelineStart))")
        // Cleanup happens in the function-level defer above.
    }

    // MARK: - Channel transcribe helper

    /// Transcribes one channel (mic or system) and stamps the speaker label
    /// onto each segment. Static + nonisolated so the two channels can run
    /// concurrently via `async let` without serializing through MainActor.
    /// Failures swallow to an empty array — the meeting still ships with
    /// whatever the other channel produced.
    nonisolated private static func transcribeChannel(
        audioURL: URL,
        model: String,
        speaker: SpeakerLabel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> [TranscriptSegment] {
        let segments = (try? await WhisperKitClient.fileTranscribe(
            audioPath: audioURL,
            model: model,
            progress: onProgress
        )) ?? []
        return segments.map {
            TranscriptSegment(id: $0.id, start: $0.start, end: $0.end,
                              text: $0.text, confidence: $0.confidence,
                              speaker: speaker, cleanedText: $0.cleanedText)
        }
    }

    // MARK: - Phase tracking

    private func setPhase(_ phase: MeetingProcessingPhase, for meeting: Meeting) {
        processingPhase = phase
        DebugLog.shared.log(icon: "🎬", label: "Phase",
                            value: "\(phase.rawValue) · \(meeting.folderName)")
    }

    /// Pretty-prints elapsed time to the debug log for the just-finished
    /// phase. Used by every step of `runPostProcessing` to make slow phases
    /// instantly visible in the Debug Log window. Resolves the user's
    /// complaint that "Transcribe took super long" by giving them a number
    /// to look at.
    private func logPhaseElapsed(_ name: String, since: Date, detail: String? = nil) {
        let value = detail.map { "\($0) · \(Self.elapsedString(since: since))" }
                          ?? Self.elapsedString(since: since)
        DebugLog.shared.log(icon: "⏱", label: "\(name) done", value: value)
    }

    nonisolated static func elapsedString(since start: Date) -> String {
        let s = Date().timeIntervalSince(start)
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return "\(m)m\(r)s"
    }

    // MARK: - Calendar auto-link

    private func autoLinkCalendarEvent(meeting: Meeting) async -> Meeting {
        let calendar = CalendarIntegration.shared
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = calendar.authStatus == .fullAccess
        } else {
            granted = calendar.authStatus == .authorized
        }
        guard granted else { return meeting }
        // Require positive time overlap to auto-link. Without this guard
        // `bestMatch` happily returns an event whose only relationship to
        // the recording is being inside the ±15 min search window — e.g.
        // the call right before the one you recorded. That event's title
        // and attendees would be written to disk and into the summary
        // prompt with no user confirmation. Require at least 60s of
        // overlap; below that we leave it alone and let the user link
        // manually from the detail view.
        guard let (event, overlap) = calendar.bestOverlap(for: meeting),
              overlap >= 60,
              let title = event.title, !title.isEmpty,
              let eventID = event.eventIdentifier else {
            return meeting
        }
        var updated = meeting
        updated.calendarEventTitle = title
        updated.calendarEventID = eventID
        let attendees = calendar.attendeeNames(for: event)
        var existing = Set(updated.participants.map { $0.lowercased() })
        for name in attendees where !existing.contains(name.lowercased()) {
            updated.participants.append(name)
            existing.insert(name.lowercased())
        }
        updated.updatedAt = Date()
        try? store.update(updated)
        DebugLog.shared.log(icon: "📅", label: "Calendar auto-linked",
                            value: "\(title) · overlap=\(Int(overlap))s · \(attendees.count) attendees")
        return updated
    }

    /// Picks the configured skill + LLM, runs the summary, persists it.
    /// Returns the summary markdown (or an empty string on failure).
    private func runSummary(meeting: Meeting,
                            segments: [TranscriptSegment]) async -> String {
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

    /// Fires Hermes + Obsidian + (future) generic webhooks. Failures log
    /// but don't block other integrations. Thin wrapper over the shared
    /// `IntegrationFanout` helper so the on-demand button in the detail
    /// view and the auto-fire path stay in lockstep.
    private func fanOutToIntegrations(meeting: Meeting,
                                       transcriptMarkdown: String,
                                       summaryMarkdown: String) async {
        _ = await IntegrationFanout.send(
            meeting: meeting,
            transcriptMarkdown: transcriptMarkdown,
            summaryMarkdown: summaryMarkdown,
            audioFileURL: store.audioFileURL(for: meeting)
        )
    }

    // MARK: - Stitching

    /// Concatenates `chunk-NNNN-<prefix>.wav` files in order into `output`.
    private nonisolated func stitchChunks(in chunksDir: URL,
                                          prefix: String,
                                          to output: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: chunksDir.path) else { return }
        let entries = (try? fm.contentsOfDirectory(at: chunksDir,
                                                    includingPropertiesForKeys: nil)) ?? []
        let chunks = entries
            .filter { $0.lastPathComponent.contains("-\(prefix).wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let first = chunks.first else { return }

        let firstFile = try AVAudioFile(forReading: first)
        let writer = try AVAudioFile(forWriting: output,
                                     settings: firstFile.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        for chunkURL in chunks {
            let reader = try AVAudioFile(forReading: chunkURL)
            let format = reader.processingFormat
            let frameCapacity = AVAudioFrameCount(reader.length)
            guard frameCapacity > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: frameCapacity) else {
                continue
            }
            try reader.read(into: buffer)
            try writer.write(from: buffer)
        }
    }

    /// Quick mix: average the mic + system PCM streams. v0.4b adds RMS ducking.
    /// Mismatched durations are accepted — output length = max(mic, system).
    private nonisolated func mixToCombined(mic micURL: URL,
                                            system systemURL: URL,
                                            output: URL) throws {
        let fm = FileManager.default
        let micExists = fm.fileExists(atPath: micURL.path)
        let systemExists = fm.fileExists(atPath: systemURL.path)
        guard micExists || systemExists else { return }

        // If only one channel survived, just copy it as the combined.
        if micExists && !systemExists {
            try? fm.removeItem(at: output)
            try fm.copyItem(at: micURL, to: output)
            return
        }
        if !micExists && systemExists {
            try? fm.removeItem(at: output)
            try fm.copyItem(at: systemURL, to: output)
            return
        }

        let micFile = try AVAudioFile(forReading: micURL)
        let systemFile = try AVAudioFile(forReading: systemURL)
        let outFormat = micFile.processingFormat   // pin to mic's format
        let writer = try AVAudioFile(forWriting: output,
                                     settings: micFile.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)

        let block: AVAudioFrameCount = 4096
        let micFrames = AVAudioFrameCount(micFile.length)
        let sysFrames = AVAudioFrameCount(systemFile.length)
        let totalFrames = max(micFrames, sysFrames)

        let micBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: block)!
        let sysBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: block)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: block)!

        // Side-chain ducking enabled by default; user can disable via Settings.
        let duck = (UserDefaults.standard.object(forKey: "meetingsAudioDucking") as? Bool) ?? true
        var mixer = AudioMixer()
        mixer.sampleRate = Float(outFormat.sampleRate)
        mixer.reset()

        var written: AVAudioFrameCount = 0
        while written < totalFrames {
            let want = min(block, totalFrames - written)
            try? micFile.read(into: micBuf, frameCount: want)
            try? systemFile.read(into: sysBuf, frameCount: want)
            outBuf.frameLength = want
            if duck {
                mixer.mix(mic: micBuf, system: sysBuf, out: outBuf)
            } else {
                outBuf.frameLength = micBuf.frameLength
                mixInto(out: outBuf, a: micBuf, b: sysBuf, frames: Int(want))
            }
            try writer.write(from: outBuf)
            written += want
        }
    }

    /// Naive sum used when ducking is off. AudioMixer does the proper RMS-side-chain.
    private nonisolated func mixInto(out: AVAudioPCMBuffer,
                                      a: AVAudioPCMBuffer,
                                      b: AVAudioPCMBuffer,
                                      frames: Int) {
        guard let outData = out.floatChannelData,
              let aData = a.floatChannelData,
              let bData = b.floatChannelData else { return }
        let outChannels = Int(out.format.channelCount)
        let aChannels = Int(a.format.channelCount)
        let bChannels = Int(b.format.channelCount)
        for ch in 0..<outChannels {
            let aCh = ch < aChannels ? aData[ch] : aData[0]
            let bCh = ch < bChannels ? bData[ch] : bData[0]
            for i in 0..<frames {
                outData[ch][i] = (aCh[i] + bCh[i]) * 0.5
            }
        }
    }

    private nonisolated func audioDurationSeconds(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(f.length)
        let rate = f.processingFormat.sampleRate
        return rate > 0 ? frames / rate : nil
    }

    private nonisolated func renderMarkdown(_ doc: TranscriptDocument, title: String) -> String {
        var out = "# \(title)\n\n"
        for s in doc.segments {
            let speaker = s.speaker == .me ? "[Me]" : (s.speaker == .other ? "[Other]" : "")
            let stamp = formatTimestamp(s.start)
            out += "**\(stamp)** \(speaker) \(s.text)\n\n"
        }
        return out
    }

    private nonisolated func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Permission helper

    private func requestMicPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
        default: return false
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    // MARK: - Slug helpers

    private static let slugFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let humanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale.current
        return f
    }()

    private static func timeSlug(_ date: Date) -> String { slugFormatter.string(from: date) }
    private static func humanTimeStamp(_ date: Date) -> String { humanFormatter.string(from: date) }
}

