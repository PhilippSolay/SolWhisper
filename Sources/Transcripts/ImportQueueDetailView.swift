import SwiftUI

/// Detail-area view for the import queue. Shown while files are importing:
/// the active file gets the full pipeline tracker (Transcribe → Clean →
/// Diarize → Summarize → Send); queued files list below; finished files show a
/// compact result row. No floating windows — everything lives here.
struct ImportQueueDetailView: View {

    @ObservedObject var queue: ImportQueue
    /// Selects a finished meeting (called from a done row's "Open").
    let onOpenMeeting: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(queue.items) { item in
                        row(for: item)
                    }
                }
                .padding(16)
            }
            Divider()
            footerHint
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Importing audio")
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if queue.hasUnfinished {
                Button("Cancel all") { queue.cancelAll() }
            } else {
                Button("Clear") { queue.clearFinished() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        if let summary = queue.summaryLine { return summary }
        if let pos = queue.activePosition { return "\(pos) of \(queue.total) · continues past failures" }
        return "\(queue.total) queued"
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: ImportQueue.Item) -> some View {
        switch item.status {
        case .active:          activeCard(item)
        case .queued:          compactRow(item, icon: "circle.dashed", tint: .secondary, trailing: "queued", removable: true)
        case .done:            doneRow(item)
        case .failed(let msg): compactRow(item, icon: "exclamationmark.triangle.fill", tint: .red, trailing: msg, removable: false)
        case .cancelled:       compactRow(item, icon: "slash.circle", tint: .secondary, trailing: "cancelled", removable: false)
        }
    }

    private func activeCard(_ item: ImportQueue.Item) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 15))
                    .foregroundColor(.accentColor)
                Text(item.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { queue.cancel(item.id) }
                    .controlSize(.small)
            }
            MeetingPipelineProgress(steps: buildSteps(item), totalElapsed: nil)
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
        )
    }

    private func doneRow(_ item: ImportQueue.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.green)
            Text(item.filename)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let meetingID = item.meetingID {
                Button("Open") { onOpenMeeting(meetingID) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    private func compactRow(_ item: ImportQueue.Item,
                            icon: String,
                            tint: Color,
                            trailing: String,
                            removable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(tint)
            Text(item.filename)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(trailing)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if removable {
                Button {
                    queue.cancel(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Footer

    private var footerHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("Drop audio anywhere in this window, or use “Upload or drop file”.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Pipeline tracker

    private func buildSteps(_ item: ImportQueue.Item) -> [MeetingPipelineProgress.Step] {
        ImportQueue.pipelineSteps.map { phase in
            MeetingPipelineProgress.Step(
                id: phase,
                label: shortLabel(phase),
                icon: phase.iconName,
                status: stepStatus(phase, for: item),
                fraction: phase == .transcribing ? item.stageFraction : nil
            )
        }
    }

    private func stepStatus(_ phase: MeetingProcessingPhase,
                            for item: ImportQueue.Item) -> MeetingPipelineProgress.StepStatus {
        // Optional stages the user has disabled render as skipped.
        if phase != .transcribing, !item.enabledStages.contains(phase) { return .skipped }
        let order = ImportQueue.pipelineSteps
        guard let current = order.firstIndex(of: item.stage),
              let mine = order.firstIndex(of: phase) else { return .pending }
        if mine < current { return .done }
        if mine == current { return .running }
        return .pending
    }

    private func shortLabel(_ phase: MeetingProcessingPhase) -> String {
        switch phase {
        case .stitching:    return "Stitch"
        case .transcribing: return "Transcribe"
        case .cleaning:     return "Clean"
        case .diarizing:    return "Diarize"
        case .summarizing:  return "Summarize"
        case .integrating:  return "Send"
        }
    }
}
