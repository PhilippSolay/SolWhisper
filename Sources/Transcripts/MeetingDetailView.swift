import EventKit
import SwiftUI

/// Right pane: header card + audio scrubber + transcript scroll.
/// Read-only in Sprint 3 — title editing, cleanup, summarize all defer.
struct MeetingDetailView: View {

    let meeting: Meeting
    @ObservedObject var store: MeetingStore
    let onDeleted: () -> Void

    @State private var transcript: TranscriptDocument?
    @State private var loadError: String?
    @State private var showDeleteConfirm = false
    @State private var showSkillPicker = false
    @State private var summary: Summary?
    @State private var summarizing: Bool = false
    @State private var summaryError: String?
    @State private var cleaning: Bool = false
    @State private var cleanError: String?
    @State private var cleanReport: CleanupPass.Report?
    @State private var retranscribing: Bool = false
    @State private var retranscribeError: String?
    @State private var retranscribeProgress: Double?
    @State private var diarizing: Bool = false
    @State private var diarizeError: String?
    @State private var diarizeProgress: Double?
    @State private var suggesting: Bool = false
    @State private var suggestError: String?
    @State private var suggestSheet: [SpeakerNameSuggester.Suggestion]?
    @StateObject private var calendar = CalendarIntegration.shared
    @StateObject private var voiceProfiles = VoiceProfileStore.shared
    @State private var calendarCandidates: [String] = []
    @State private var calendarMatchSheet: CalendarMatchPayload?
    /// Cached candidate-name pool. Rebuilt only when the source pieces
    /// change (calendar candidates / meeting / voice profiles), not on
    /// every body re-render.
    @State private var cachedNameCandidates: [String] = []
    /// Cached visible-segment list. Rebuilt when the transcript changes,
    /// not on every body re-render.
    @State private var cachedVisibleSegments: [TranscriptSegment] = []
    @State private var titleDraft: String = ""
    @State private var titleEditing: Bool = false
    @State private var contextDraft: String = ""
    @State private var contextChanged: Bool = false
    @State private var bodyTab: BodyTab = .transcript
    @State private var copyState: CopyState = .idle

    enum BodyTab: String, CaseIterable, Identifiable {
        case transcript, summary
        var id: String { rawValue }
        var label: String { self == .transcript ? "Transcript" : "Summary" }
    }
    enum CopyState { case idle, copied }
    @StateObject private var playback = PlaybackHolder()
    @StateObject private var skillsRegistry = SkillsRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    actionRow
                    titleAndMeta
                    calendarEventBox
                    contextField
                    if let err = retranscribeError {
                        Text(err).font(.system(size: 12)).foregroundColor(.red)
                    }
                    if let err = cleanError {
                        Text(err).font(.system(size: 12)).foregroundColor(.red)
                    }
                    if let err = diarizeError {
                        Text(err).font(.system(size: 12)).foregroundColor(.red)
                    }
                    if let err = suggestError {
                        Text(err).font(.system(size: 12)).foregroundColor(.red)
                    }
                    if let err = summaryError, summary == nil {
                        Text(err).font(.system(size: 12)).foregroundColor(.red)
                    }
                    bodyTabBar
                    Group {
                        switch bodyTab {
                        case .transcript:
                            transcriptSection
                        case .summary:
                            if let summary {
                                summarySection(summary)
                            } else {
                                emptySummaryState
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Sticky audio player — always visible, even while scrolling
            // through long transcripts. Pinned to the bottom edge of the
            // detail pane with a hairline divider + subtle backdrop.
            if playback.controller != nil {
                Divider()
                audioBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .onAppear { reloadAll() }
        .onChange(of: meeting.id) { _ in reloadAll() }
        // Keep caches in sync with the underlying data without redoing
        // the work on every keystroke.
        .onChange(of: transcript?.segments.count ?? -1) { _ in rebuildVisibleSegments() }
        .onChange(of: calendarCandidates) { _ in rebuildNameCandidates() }
        .onChange(of: voiceProfiles.profiles.count) { _ in rebuildNameCandidates() }
        .onChange(of: meeting.participants) { _ in rebuildNameCandidates() }
        .alert("Delete this meeting?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                deleteMeeting()
            }
        } message: {
            Text("\"\(meeting.title)\" will be moved to the Trash. Audio files, transcripts, and the summary go with it.")
        }
        .sheet(item: Binding(
            get: { suggestSheet.map { SuggestPayload(items: $0) } },
            set: { newValue in
                if newValue == nil { suggestSheet = nil }
            }
        )) { payload in
            SuggestNamesSheet(
                initialSuggestions: payload.items,
                calendarCandidates: calendarCandidates,
                onApply: { map in
                    applySuggestedNames(map)
                    suggestSheet = nil
                },
                onCancel: { suggestSheet = nil }
            )
        }
        .sheet(item: Binding(
            get: { cleanReport.map { CleanReportPayload(report: $0) } },
            set: { newValue in if newValue == nil { cleanReport = nil } }
        )) { payload in
            CleanReportSheet(report: payload.report) { cleanReport = nil }
        }
        .sheet(item: $calendarMatchSheet) { payload in
            CalendarMatchSheet(
                candidates: payload.candidates,
                bestMatch: payload.bestMatch,
                attendeeNames: { calendar.attendeeNames(for: $0) },
                onConfirm: { title, attendees, eventID in
                    confirmCalendarLink(title: title, attendees: attendees, eventID: eventID)
                    calendarMatchSheet = nil
                },
                onSkip: { calendarMatchSheet = nil },
                onCancel: { calendarMatchSheet = nil }
            )
        }
    }

    /// Trivial Identifiable wrapper so we can drive `.sheet(item:)` off
    /// the optional suggestion array.
    private struct SuggestPayload: Identifiable {
        let id = UUID()
        let items: [SpeakerNameSuggester.Suggestion]
    }

    /// Same wrapper pattern for the clean report sheet.
    private struct CleanReportPayload: Identifiable {
        let id = UUID()
        let report: CleanupPass.Report
    }

    private func reloadAll() {
        loadContent()
        preparePlayback()
        loadSummary()
        titleDraft = meeting.title
        contextDraft = meeting.context ?? ""
        contextChanged = false
        bodyTab = .transcript
        refreshCalendarCandidates()
        rebuildVisibleSegments()
        rebuildNameCandidates()
    }

    private func summarySection(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("· \(summary.skillId) · \(summary.llmModel)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if let attributed = try? AttributedString(markdown: summary.rawMarkdown) {
                Text(attributed)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(summary.rawMarkdown)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func loadSummary() {
        summary = try? store.loadSummary(for: meeting)
    }

    // MARK: - Sections

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                runRetranscribe()
            } label: {
                if retranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-transcribe", systemImage: "arrow.clockwise")
                }
            }
            .disabled(retranscribing || cleaning || summarizing)
            .help("Re-run WhisperKit on the saved audio file. Useful if you change the model or the previous transcript was bad.")

            Button {
                runClean()
            } label: {
                if cleaning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Clean", systemImage: "wand.and.sparkles")
                }
            }
            .disabled(cleaning || summarizing || retranscribing || (transcript?.segments.isEmpty ?? true))
            .help("Remove filler words, fix punctuation, tighten grammar — preserves every substantive word.")

            Button {
                runDiarize()
            } label: {
                if diarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Diarize", systemImage: "person.2.wave.2")
                }
            }
            .disabled(diarizing || cleaning || summarizing || retranscribing || (transcript?.segments.isEmpty ?? true))
            .help("Tag each segment with a speaker letter (A, B, C…) using the engine picked in Settings → Models → Diarization.")

            Button {
                runSuggestNames()
            } label: {
                if suggesting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Suggest names", systemImage: "person.text.rectangle")
                }
            }
            .disabled(suggesting || diarizing || (transcript?.segments.contains(where: { $0.speakerID != nil }) != true))
            .help("Ask the LLM to propose Speaker A→Pierre, B→Ricardo… mappings using the meeting context, calendar attendees, and voice profile names.")

            Button {
                showSkillPicker = true
            } label: {
                if summarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Summarize", systemImage: "sparkles")
                }
            }
            .disabled(summarizing || retranscribing)
            .popover(isPresented: $showSkillPicker, arrowEdge: .top) {
                skillPickerPopover
            }

            Button {
                copyTranscriptMarkdown()
            } label: {
                if copyState == .copied {
                    Label("Copied!", systemImage: "checkmark")
                } else {
                    Label("Copy MD", systemImage: "doc.on.doc")
                }
            }
            .disabled((transcript?.segments.isEmpty ?? true))
            .help("Copy the transcript as Markdown to the clipboard.")

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .controlSize(.regular)
    }

    private var titleAndMeta: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Click to edit; commit on submit / focus loss.
            ZStack(alignment: .leading) {
                if titleEditing {
                    TextField("Title", text: $titleDraft, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))
                } else {
                    Text(titleDraft.isEmpty ? meeting.title : titleDraft)
                        .font(.system(size: 22, weight: .semibold))
                        .onTapGesture(count: 2) {
                            titleDraft = meeting.title
                            titleEditing = true
                        }
                        .help("Double-click to edit")
                }
            }

            HStack(spacing: 8) {
                Text(formatDate(meeting.createdAt))
                if meeting.durationSeconds > 0 {
                    Text("·")
                    Text(formatDuration(meeting.durationSeconds))
                }
                Text("·")
                Text(meeting.source == .recording ? "Recording" : "Imported")
                if let app = meeting.sourceApp {
                    Text("·")
                    Text(app)
                }
                Text("·")
                Text(meeting.transcriptionBackend)
                    .font(.system(.caption, design: .monospaced))
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
    }

    /// Calendar-event card. Shows three states:
    ///   1. Linked → event title + attendee list + Change/Unlink actions
    ///   2. Calendar permission granted but unlinked → "Link calendar event" button
    ///   3. Permission missing → "Grant Calendar access in Settings → People"
    @ViewBuilder
    private var calendarEventBox: some View {
        if let title = meeting.calendarEventTitle {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 12))
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button {
                        runOpenCalendarMatch()
                    } label: {
                        Text("Change")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    Button {
                        unlinkCalendarEvent()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Unlink this event from the meeting")
                }
                if !meeting.participants.isEmpty {
                    Text("Attendees")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(meeting.participants.joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("No attendees on this event")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
            )
        } else {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                Text("No calendar event linked")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    runOpenCalendarMatch()
                } label: {
                    Label("Link calendar event…", systemImage: "calendar.badge.plus")
                        .font(.system(size: 12))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
            )
        }
    }

    /// Identifiable wrapper so we can drive `.sheet(item:)` off optional state.
    fileprivate struct CalendarMatchPayload: Identifiable {
        let id = UUID()
        let candidates: [EKEvent]
        let bestMatch: EKEvent?
    }

    private func runOpenCalendarMatch() {
        Task { @MainActor in
            // Check / request permission first.
            let granted = await calendar.requestAccessIfNeeded()
            if !granted {
                DebugLog.shared.log(icon: "📅", label: "Calendar access denied",
                                    value: "User declined or System Settings blocks access",
                                    ok: false)
                return
            }
            let candidates = calendar.eventsAroundMeeting(meeting)
            calendarMatchSheet = CalendarMatchPayload(
                candidates: candidates,
                bestMatch: calendar.bestMatch(for: meeting)
            )
        }
    }

    private func confirmCalendarLink(title: String, attendees: [String], eventID: String) {
        var updated = meeting
        updated.calendarEventTitle = title
        updated.calendarEventID = eventID
        // Merge attendees into participants — don't overwrite if user has
        // already typed names by hand. Dedupe case-insensitive.
        var existing = Set(updated.participants.map { $0.lowercased() })
        for name in attendees where !existing.contains(name.lowercased()) {
            updated.participants.append(name)
            existing.insert(name.lowercased())
        }
        updated.updatedAt = Date()
        try? store.update(updated)
        DebugLog.shared.log(icon: "📅", label: "Calendar event linked",
                            value: "\(title) · \(attendees.count) attendees")
        // Refresh local candidate cache so the suggester + rename popover
        // see the new attendees immediately.
        refreshCalendarCandidates()
    }

    private func unlinkCalendarEvent() {
        var updated = meeting
        updated.calendarEventTitle = nil
        updated.calendarEventID = nil
        updated.updatedAt = Date()
        try? store.update(updated)
        DebugLog.shared.log(icon: "📅", label: "Calendar event unlinked",
                            value: meeting.calendarEventTitle ?? "?")
    }

    private var contextField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.bubble")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                Text("Context")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if contextChanged {
                    Button("Save") { commitContext() }
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            TextEditor(text: $contextDraft)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 56, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.30), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if contextDraft.isEmpty {
                        Text("Add background the model should know — attendees' roles, prior decisions, what to focus on.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: contextDraft) { newValue in
                    contextChanged = newValue != (meeting.context ?? "")
                }
        }
    }

    private var bodyTabBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $bodyTab) {
                ForEach(BodyTab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
    }

    private var emptySummaryState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No summary yet")
                .font(.system(size: 13, weight: .medium))
            Text("Click Summarize and pick a meeting type. The summary appears here.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // MARK: - Title + context persistence

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != meeting.title {
            var updated = meeting
            updated.title = trimmed
            updated.updatedAt = Date()
            try? store.update(updated)
        }
        titleEditing = false
    }

    private func commitContext() {
        var updated = meeting
        updated.context = contextDraft.isEmpty ? nil : contextDraft
        updated.updatedAt = Date()
        try? store.update(updated)
        contextChanged = false
    }

    // MARK: - Copy MD

    private func copyTranscriptMarkdown() {
        guard let document = transcript else { return }
        let md = FileTranscriber.renderMarkdown(document, title: meeting.title)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        copyState = .copied
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copyState == .copied { copyState = .idle }
        }
    }

    // MARK: - Re-transcribe

    /// Loads calendar attendees for this meeting (best-match event by
    /// time overlap). Used as a candidate pool for the LLM suggester +
    /// the rename popover's autocomplete dropdown.
    private func refreshCalendarCandidates() {
        Task { @MainActor in
            // Only proceed if access is already granted; we don't prompt
            // here — the user grants from Settings → People.
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = calendar.authStatus == .fullAccess
            } else {
                granted = calendar.authStatus == .authorized
            }
            guard granted else {
                calendarCandidates = []
                return
            }
            if let event = calendar.bestMatch(for: meeting) {
                calendarCandidates = calendar.attendeeNames(for: event)
                DebugLog.shared.log(icon: "📅", label: "Calendar match",
                                    value: "\(event.title ?? "?") · \(calendarCandidates.count) attendees")
            } else {
                calendarCandidates = []
            }
        }
    }

    private func runSuggestNames() {
        suggesting = true
        suggestError = nil
        Task { @MainActor in
            defer { suggesting = false }
            guard let document = transcript else {
                suggestError = "No transcript loaded yet."
                return
            }
            // Build the candidate pool: meeting.participants ∪
            // calendar attendees ∪ saved voice profile names.
            var pool = Set<String>(meeting.participants)
            pool.formUnion(calendarCandidates)
            pool.formUnion(voiceProfiles.allNames)
            let candidates = Array(pool).sorted()
            do {
                let suggestions = try await SpeakerNameSuggester.suggest(
                    transcript: document,
                    meeting: meeting,
                    candidates: candidates
                )
                suggestSheet = suggestions
            } catch let err as SpeakerNameSuggester.SuggesterError {
                suggestError = err.localizedDescription
            } catch {
                suggestError = error.localizedDescription
            }
        }
    }

    /// Apply a batch of mappings from the suggest sheet.
    private func applySuggestedNames(_ map: [String: String]) {
        var updated = meeting
        var names = updated.speakerNames ?? [:]
        for (letter, name) in map {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names[letter] = trimmed }
        }
        updated.speakerNames = names.isEmpty ? nil : names
        updated.updatedAt = Date()
        try? store.update(updated)
        DebugLog.shared.log(icon: "👥", label: "Speaker names applied",
                            value: "\(map.count) mappings")
    }

    /// Rebuilds the candidate-name pool from sources (participants +
    /// calendar attendees + voice profiles). Deduped and sorted. Called
    /// only when source data changes, not on every body re-render.
    private func rebuildNameCandidates() {
        var pool = Set<String>(meeting.participants)
        pool.formUnion(calendarCandidates)
        pool.formUnion(voiceProfiles.allNames)
        cachedNameCandidates = Array(pool).sorted()
    }

    /// Rebuilds the visible-segment list from the current transcript.
    /// Filters out segments cleanup blanked out (cleanedText == "").
    private func rebuildVisibleSegments() {
        guard let transcript = transcript else {
            cachedVisibleSegments = []
            return
        }
        cachedVisibleSegments = transcript.segments.filter { seg in
            if let cleaned = seg.cleanedText {
                return !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    private func saveAsVoiceProfile(letter: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Dedupe by name (case-insensitive). If a profile with this name
        // already exists, reuse it — but still run the embedding capture
        // below so name-only profiles get upgraded to voiceprint-stored.
        let existing = voiceProfiles.profiles.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })

        let profile: VoiceProfile
        if let existing {
            profile = existing
            DebugLog.shared.log(icon: "👥", label: "Voice profile reused",
                                value: "\(trimmed) (Speaker \(letter))")
        } else {
            profile = VoiceProfile(
                name: trimmed,
                sourceMeetingID: meeting.id,
                sourceSpeakerLetter: letter
            )
            voiceProfiles.add(profile)
            DebugLog.shared.log(icon: "👥", label: "Voice profile saved",
                                value: "\(trimmed) (Speaker \(letter))")
        }

        // Capture a voiceprint unless this profile already has one — every
        // saved speaker should end up with an embedding so future meetings
        // auto-match them. Skip if the profile is already voiceprint-stored
        // to avoid redundant work.
        if profile.hasEmbedding {
            DebugLog.shared.log(icon: "👥", label: "Voiceprint already stored",
                                value: trimmed)
            return
        }
        if #available(macOS 14.0, *) {
            captureEmbedding(for: profile, letter: letter)
        }
    }

    @available(macOS 14.0, *)
    private func captureEmbedding(for profile: VoiceProfile, letter: String) {
        guard let document = transcript else { return }
        let folder = store.folderURL(for: meeting)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let audioURL = candidates.first(where: {
            $0.lastPathComponent.hasPrefix("audio.")
        }) else {
            DebugLog.shared.log(icon: "👥", label: "Voiceprint skipped",
                                value: "no audio file in meeting folder",
                                ok: false)
            return
        }
        Task { @MainActor in
            do {
                try await VoiceProfileEmbedder.capture(
                    profile: profile,
                    speakerLetter: letter,
                    in: document,
                    audioURL: audioURL,
                    store: voiceProfiles
                )
            } catch let err as VoiceProfileEmbedder.EmbedError {
                DebugLog.shared.log(icon: "👥", label: "Voiceprint capture failed",
                                    value: err.localizedDescription, ok: false)
            } catch {
                DebugLog.shared.log(icon: "👥", label: "Voiceprint capture failed",
                                    value: "\(error)", ok: false)
            }
        }
    }

    private func renameSpeaker(letter: String, to newName: String) {
        var updated = meeting
        var names = updated.speakerNames ?? [:]
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: letter)
        } else {
            names[letter] = trimmed
        }
        updated.speakerNames = names.isEmpty ? nil : names
        updated.updatedAt = Date()
        try? store.update(updated)
    }

    private func runDiarize() {
        diarizing = true
        diarizeError = nil
        diarizeProgress = 0
        Task { @MainActor in
            defer { diarizing = false; diarizeProgress = nil }
            guard let document = transcript else {
                diarizeError = "No transcript loaded yet."
                return
            }
            // Find the audio file in the meeting folder.
            let folder = store.folderURL(for: meeting)
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let audioURL = candidates.first(where: {
                $0.lastPathComponent.hasPrefix("audio.")
            }) else {
                diarizeError = "Audio file not found in this meeting's folder."
                return
            }
            let outcome = await DiarizationRunner.run(
                meeting: meeting,
                transcript: document,
                audioURL: audioURL,
                store: store,
                progress: { f in diarizeProgress = f }
            )
            switch outcome {
            case .noEngine:
                diarizeError = "No diarization engine configured. Pick one in Settings → Models → Diarization."
            case .failed(let msg):
                diarizeError = msg
            case .success(let tagged, let total, let engineID):
                DebugLog.shared.log(icon: "🎭", label: "Diarize done",
                                    value: "\(tagged)/\(total) segments tagged · engine=\(engineID)")
                // Reload transcript from disk so the view picks up speakerID.
                if let reloaded = try? store.loadTranscript(for: meeting) {
                    transcript = reloaded
                }
            }
        }
    }

    private func runRetranscribe() {
        retranscribing = true
        retranscribeError = nil
        retranscribeProgress = 0
        Task { @MainActor in
            defer { retranscribing = false; retranscribeProgress = nil }
            let folder = store.folderURL(for: meeting)
            // Find the audio file — could be audio.wav (recording) or
            // audio.<ext> (import). Pick the first match in the folder.
            let candidates = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            guard let audioURL = candidates.first(where: { $0.lastPathComponent.hasPrefix("audio.") }) else {
                retranscribeError = "Audio file not found in this meeting's folder."
                return
            }
            let model = UserDefaults.standard.string(forKey: "meetingsWhisperKitModel")
                     ?? WhisperKitClient.defaultModel
            do {
                let result = try await FileTranscriber.transcribe(
                    audioURL: audioURL,
                    meetingID: meeting.id,
                    model: model,
                    progress: { fraction in retranscribeProgress = fraction }
                )
                try store.writeTranscript(result.document, for: meeting)
                let md = FileTranscriber.renderMarkdown(result.document, title: meeting.title)
                try store.writeTranscriptMarkdown(md, for: meeting)
                transcript = result.document
                DebugLog.shared.log(icon: "🔁", label: "Re-transcribe done",
                                    value: "\(result.document.segments.count) segments · model=\(model)")
            } catch {
                retranscribeError = error.localizedDescription
                DebugLog.shared.log(icon: "🔁", label: "Re-transcribe failed",
                                    value: "\(error)", ok: false)
            }
        }
    }

    private func deleteMeeting() {
        playback.controller?.pause()
        playback.controller = nil
        do {
            try store.delete(meeting)
            onDeleted()
        } catch {
            DebugLog.shared.log(icon: "🗑", label: "Delete failed",
                                value: "\(error)", ok: false)
        }
    }

    // MARK: - Summarize popover

    private var skillPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Meeting Summary pack — primary path, with sub-type options.
            if let pack = skillsRegistry.meetingSummaryPack {
                Text(pack.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                Divider()

                packTypeButton(pack: pack, typeID: nil,
                               title: "Auto-detect type",
                               subtitle: "Let the model classify from the transcript")
                ForEach(pack.typeIDs, id: \.self) { typeID in
                    packTypeButton(
                        pack: pack,
                        typeID: typeID,
                        title: prettyTypeName(typeID),
                        subtitle: pack.types[typeID]?.description ?? ""
                    )
                }

                if !skillsRegistry.skills.isEmpty {
                    Divider().padding(.top, 4)
                    Text("Other skills")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    Divider()
                }
            } else {
                Text("Summarize with…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                Divider()
            }

            ForEach(skillsRegistry.skills) { skill in
                Button {
                    showSkillPicker = false
                    runSummary(with: skill)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name).font(.system(size: 13, weight: .medium))
                        Text(skill.description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 360)
    }

    private func packTypeButton(pack: SkillPack,
                                typeID: String?,
                                title: String,
                                subtitle: String) -> some View {
        Button {
            showSkillPicker = false
            runPackSummary(pack: pack, meetingType: typeID)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func prettyTypeName(_ id: String) -> String {
        id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private func runClean() {
        guard let segments = transcript?.segments, !segments.isEmpty else {
            cleanError = "No transcript yet for this meeting."
            return
        }
        cleaning = true
        cleanError = nil
        Task { @MainActor in
            defer { cleaning = false }
            guard let resolved = LLMResolver.resolve(.cleanup) else {
                cleanError = "No LLM configured for cleanup. Add a model in Settings → Models."
                return
            }
            let pass = CleanupPass(client: resolved.client, model: resolved.modelID)
            do {
                let result = try await pass.cleanWithReport(segments, forceAllRulesIfEmpty: true)
                let updated = TranscriptDocument(meetingID: meeting.id, segments: result.segments)
                try store.writeTranscript(updated, for: meeting)
                transcript = updated
                cleanReport = result.report
                DebugLog.shared.log(icon: "🧹", label: "Manual clean done",
                                    value: "modified=\(result.report.segmentsModified) artifacts=\(result.report.artifactsDropped) blanked=\(result.report.segmentsBlanked) · \(resolved.providerLabel) · \(resolved.modelID)")
            } catch let err as CleanupPass.CleanError {
                if case .partial(_, let done, let total) = err {
                    // Partial = some segments did get cleaned. Persist what
                    // we have so the user keeps the work, but tell them the
                    // run was incomplete.
                    cleanError = "Cleanup partial: \(done)/\(total) segments. \(err.localizedDescription)"
                } else {
                    cleanError = err.localizedDescription
                }
                DebugLog.shared.log(icon: "🧹", label: "Manual clean failed",
                                    value: err.localizedDescription, ok: false)
            } catch {
                cleanError = error.localizedDescription
                DebugLog.shared.log(icon: "🧹", label: "Manual clean failed",
                                    value: "\(error)", ok: false)
            }
        }
    }

    private func runPackSummary(pack: SkillPack, meetingType: String?) {
        summarizing = true
        summaryError = nil
        Task { @MainActor in
            defer { summarizing = false }
            guard let segments = transcript?.segments, !segments.isEmpty else {
                summaryError = "No transcript yet for this meeting."
                return
            }
            guard let resolved = LLMResolver.resolve(.summary) else {
                summaryError = "No LLM configured for summaries. Add a model in Settings → Models."
                return
            }
            let generator = SummaryGenerator(client: resolved.client,
                                              provider: resolved.providerLabel,
                                              model: resolved.modelID)
            do {
                let s = try await generator.generate(meeting: meeting,
                                                      segments: segments,
                                                      pack: pack,
                                                      meetingType: meetingType)
                try store.writeSummary(s, for: meeting)
                summary = s
                DebugLog.shared.log(icon: "📝", label: "Pack summarize done",
                                    value: "type=\(s.meetingType ?? "?") · \(resolved.modelID)")
            } catch {
                summaryError = error.localizedDescription
                DebugLog.shared.log(icon: "📝", label: "Pack summarize failed",
                                    value: "\(error)", ok: false)
            }
        }
    }

    private func runSummary(with skill: Skill) {
        summarizing = true
        summaryError = nil
        Task { @MainActor in
            defer { summarizing = false }
            // Pull segments from the loaded transcript.
            guard let segments = transcript?.segments, !segments.isEmpty else {
                summaryError = "No transcript yet for this meeting."
                return
            }
            guard let resolved = LLMResolver.resolve(.summary) else {
                summaryError = "No LLM configured for summaries. Add a model in Settings → Models."
                return
            }
            let generator = SummaryGenerator(client: resolved.client,
                                              provider: resolved.providerLabel,
                                              model: resolved.modelID)
            do {
                let s = try await generator.generate(meeting: meeting,
                                                      segments: segments,
                                                      skill: skill)
                try store.writeSummary(s, for: meeting)
                summary = s
            } catch {
                summaryError = error.localizedDescription
                DebugLog.shared.log(icon: "📝", label: "Manual summarize failed",
                                    value: "\(error)", ok: false)
            }
        }
    }

    @ViewBuilder
    private var audioBar: some View {
        if let controller = playback.controller {
            AudioBarView(controller: controller)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            if let err = loadError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            } else if let transcript {
                if transcript.segments.isEmpty {
                    Text("No segments in transcript.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                } else if cachedVisibleSegments.isEmpty {
                    Text("Cleanup removed every segment as non-speech. Re-transcribe with a higher-accuracy model (Settings → Models → STT Meetings → large-v3-turbo) for better results.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                } else {
                    // LazyVStack only renders rows currently in the
                    // viewport — critical for 1h+ meetings with hundreds
                    // of segments. Combined with the cached candidate
                    // pool and Equatable-row trick below, this keeps
                    // scrolling smooth.
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(cachedVisibleSegments) { segment in
                            TranscriptSegmentRow(
                                segment: segment,
                                speakerNames: meeting.speakerNames ?? [:],
                                nameCandidates: cachedNameCandidates,
                                onTap: {
                                    playback.controller?.seek(to: segment.start)
                                    playback.controller?.play()
                                },
                                onRenameSpeaker: { letter, newName in
                                    renameSpeaker(letter: letter, to: newName)
                                },
                                onSaveAsProfile: { letter, name in
                                    saveAsVoiceProfile(letter: letter, name: name)
                                }
                            )
                            .equatable()
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Loaders

    private func loadContent() {
        transcript = nil
        loadError = nil
        do {
            transcript = try store.loadTranscript(for: meeting)
        } catch {
            loadError = "Couldn't load transcript: \(error)"
        }
    }

    private func preparePlayback() {
        playback.controller?.pause()
        playback.controller = nil
        if let url = store.audioFileURL(for: meeting) {
            playback.controller = AudioPlaybackController(url: url)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Transcript row

private struct TranscriptSegmentRow: View, Equatable {
    let segment: TranscriptSegment
    let speakerNames: [String: String]
    let nameCandidates: [String]
    let onTap: () -> Void
    let onRenameSpeaker: (_ letter: String, _ newName: String) -> Void
    let onSaveAsProfile: (_ letter: String, _ name: String) -> Void

    @State private var renamePopoverShowing = false
    @State private var renameDraft: String = ""

    /// The user's own display name (e.g. "Philipp"). When a speaker badge
    /// resolves to this name (case-insensitive), or when the segment is on
    /// the `.me` channel, the badge renders in white instead of the
    /// hash-assigned palette color so the user can spot themselves at a
    /// glance. Set in Settings → People → "You".
    @AppStorage("userDisplayName") private var userDisplayName: String = ""

    /// Value-only equality: closures aren't comparable, but they don't
    /// affect the rendered output as long as the static segment data and
    /// speakerNames/candidates are the same. SwiftUI uses this to
    /// short-circuit re-renders during scroll + popover state churn.
    static func == (lhs: TranscriptSegmentRow, rhs: TranscriptSegmentRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.speakerNames == rhs.speakerNames
            && lhs.nameCandidates == rhs.nameCandidates
    }

    /// True when `displayName` matches the user's configured own name.
    /// Empty `userDisplayName` always returns false so we don't accidentally
    /// whitewash every unconfigured row.
    private func isMe(_ displayName: String) -> Bool {
        let me = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !me.isEmpty else { return false }
        return displayName.caseInsensitiveCompare(me) == .orderedSame
    }

    /// Cycling palette so each speaker letter (A..H) gets a distinct color.
    /// Muted, desaturated tones designed to read calmly on a dark background
    /// — sophisticated rather than the default saturated SwiftUI rainbow.
    private static let speakerPalette: [Color] = [
        Color(red: 0.46, green: 0.66, blue: 0.86), // soft slate blue
        Color(red: 0.62, green: 0.78, blue: 0.62), // sage green
        Color(red: 0.86, green: 0.66, blue: 0.46), // warm amber
        Color(red: 0.74, green: 0.58, blue: 0.82), // soft lavender
        Color(red: 0.86, green: 0.58, blue: 0.62), // dusty rose
        Color(red: 0.46, green: 0.74, blue: 0.74), // muted teal
        Color(red: 0.78, green: 0.62, blue: 0.50), // soft taupe
        Color(red: 0.66, green: 0.68, blue: 0.82)  // dusty periwinkle
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Button(action: onTap) {
                Text(formatTimestamp(segment.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(width: 56, alignment: .leading)
            }
            .buttonStyle(.plain)

            speakerBadge
                .fixedSize(horizontal: true, vertical: false)

            // Prefer cleanedText when the cleanup pass produced one; fall
            // back to the raw transcript otherwise.
            Text(displayText)
                .font(.system(size: 13))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var displayText: String {
        if let cleaned = segment.cleanedText,
           !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleaned
        }
        return segment.text
    }

    /// Speakers can be identified three ways:
    /// - `speakerID` letter ("A", "B", …) from diarization
    /// - Channel-based `.me` / `.other` from a live recording (mic vs system audio)
    /// - `.unknown` (e.g. imported file with no diarization yet)
    ///
    /// All three (when present) get a click-to-rename popover. We use
    /// pseudo-keys `__me__` / `__other__` in the `speakerNames` map so the
    /// channel speakers can also be associated with a real person ("[Me] →
    /// Pierre"). Diarized letters take precedence when both exist.
    @ViewBuilder
    private var speakerBadge: some View {
        if let letter = segment.speakerID, !letter.isEmpty {
            let displayName = speakerNames[letter] ?? "Speaker \(letter)"
            let baseColor = Self.speakerPalette[abs(letter.hashValue) % Self.speakerPalette.count]
            let color: Color = isMe(displayName) ? .white : baseColor
            renameableBadge(letter: letter, displayName: displayName, color: color,
                            tooltip: "Click to rename Speaker \(letter)")
        } else {
            switch segment.speaker {
            case .me:
                let displayName = speakerNames["__me__"] ?? "[Me]"
                // The mic channel is always the user — render white regardless
                // of whether userDisplayName is set.
                renameableBadge(letter: "__me__", displayName: displayName,
                                color: .white,
                                tooltip: "Click to assign a real name to the [Me] channel (your microphone).")
            case .other:
                let displayName = speakerNames["__other__"] ?? "[Other]"
                let color: Color = isMe(displayName) ? .white : Self.speakerPalette[3]
                renameableBadge(letter: "__other__", displayName: displayName,
                                color: color,
                                tooltip: "Click to assign a real name to the [Other] channel (the other side's audio).")
            case .unknown:
                Text("—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func renameableBadge(letter: String,
                                  displayName: String,
                                  color: Color,
                                  tooltip: String) -> some View {
        Button {
            renameDraft = speakerNames[letter] ?? ""
            renamePopoverShowing = true
        } label: {
            Text(displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .popover(isPresented: $renamePopoverShowing) {
            renamePopover(letter: letter)
        }
    }

    private func renamePopover(letter: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(renameTitle(for: letter))
                .font(.system(size: 12, weight: .semibold))
            TextField("Name (e.g. Pierre)", text: $renameDraft, onCommit: {
                onRenameSpeaker(letter, renameDraft)
                renamePopoverShowing = false
            })
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)

            if !nameCandidates.isEmpty {
                Text("Suggestions")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(nameCandidates, id: \.self) { candidate in
                            Button {
                                renameDraft = candidate
                            } label: {
                                Text(candidate)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                renameDraft == candidate
                                ? Color.accentColor.opacity(0.15)
                                : Color.clear
                            )
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Button("Clear") {
                    onRenameSpeaker(letter, "")
                    renamePopoverShowing = false
                }
                .controlSize(.small)
                Spacer()
                Button("Save") {
                    onRenameSpeaker(letter, renameDraft)
                    onSaveAsProfile(letter, renameDraft)
                    renamePopoverShowing = false
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(renameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Saves the name and captures a 256-dim voiceprint from this speaker's audio so future meetings auto-name them. Local + private (FluidAudio CoreML).")
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Pretty title for the rename popover. Translates the channel
    /// pseudo-keys to user-facing labels.
    private func renameTitle(for letter: String) -> String {
        switch letter {
        case "__me__":    return "[Me] is…"
        case "__other__": return "[Other] is…"
        default:          return "Speaker \(letter) is…"
        }
    }
}

// MARK: - Audio bar

private struct AudioBarView: View {
    @ObservedObject var controller: AudioPlaybackController

    var body: some View {
        HStack(spacing: 12) {
            Button { controller.toggle() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)

            Text(format(controller.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 56, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { controller.currentTime },
                    set: { controller.seek(to: $0) }
                ),
                in: 0...max(controller.duration, 0.001)
            )

            Text(format(controller.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 56, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Playback holder

@MainActor
private final class PlaybackHolder: ObservableObject {
    @Published var controller: AudioPlaybackController?
}
