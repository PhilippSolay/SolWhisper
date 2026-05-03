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
    @State private var retranscribing: Bool = false
    @State private var retranscribeError: String?
    @State private var retranscribeProgress: Double?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                actionRow
                if playback.controller != nil {
                    audioBar
                }
                titleAndMeta
                contextField
                if let err = retranscribeError {
                    Text(err).font(.system(size: 12)).foregroundColor(.red)
                }
                if let err = cleanError {
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
        .onAppear { reloadAll() }
        .onChange(of: meeting.id) { _ in reloadAll() }
        .alert("Delete this meeting?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                deleteMeeting()
            }
        } message: {
            Text("\"\(meeting.title)\" will be moved to the Trash. Audio files, transcripts, and the summary go with it.")
        }
    }

    private func reloadAll() {
        loadContent()
        preparePlayback()
        loadSummary()
        titleDraft = meeting.title
        contextDraft = meeting.context ?? ""
        contextChanged = false
        bodyTab = .transcript
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
                let cleaned = try await pass.clean(segments, forceAllRulesIfEmpty: true)
                let updated = TranscriptDocument(meetingID: meeting.id, segments: cleaned)
                try store.writeTranscript(updated, for: meeting)
                transcript = updated
                let cleanedCount = cleaned.filter { ($0.cleanedText ?? "").isEmpty == false }.count
                DebugLog.shared.log(icon: "🧹", label: "Manual clean done",
                                    value: "\(cleanedCount)/\(cleaned.count) segments · \(resolved.providerLabel) · \(resolved.modelID)")
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
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(transcript.segments) { segment in
                            TranscriptSegmentRow(segment: segment) {
                                playback.controller?.seek(to: segment.start)
                                playback.controller?.play()
                            }
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

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onTap) {
                Text(formatTimestamp(segment.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(width: 56, alignment: .leading)
            }
            .buttonStyle(.plain)

            speakerBadge
                .frame(width: 50, alignment: .leading)

            Text(segment.text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var speakerBadge: some View {
        switch segment.speaker {
        case .me:
            Text("[Me]").font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
        case .other:
            Text("[Other]").font(.system(size: 11, weight: .medium))
                .foregroundColor(.purple)
        case .unknown:
            EmptyView()
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
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
