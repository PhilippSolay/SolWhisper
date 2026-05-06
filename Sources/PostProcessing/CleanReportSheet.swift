import SwiftUI

/// Post-clean summary shown after the manual "Clean" button finishes.
/// Surfaces what changed so the user can verify the pass did what they
/// expected (and notice silently-broken cases — e.g. nothing modified).
struct CleanReportSheet: View {

    let report: CleanupPass.Report
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: report.segmentsModified > 0 || report.artifactsDropped > 0
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(report.segmentsModified > 0 || report.artifactsDropped > 0
                                     ? .green : .orange)
                    .font(.system(size: 16))
                Text("Clean complete")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(String(format: "%.1fs", report.elapsedSeconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statsGrid
                    rulesBlock
                    engineBlock
                    if report.segmentsModified == 0 && report.artifactsDropped == 0 {
                        noChangeHint
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 480)
    }

    // MARK: - Sections

    private var statsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                StatTile(value: "\(report.segmentsModified)",
                         label: "modified",
                         color: .blue)
                StatTile(value: "\(report.artifactsDropped)",
                         label: "non-speech dropped",
                         color: .orange)
                StatTile(value: "\(report.segmentsBlanked)",
                         label: "blanked by LLM",
                         color: .purple)
            }
            HStack(spacing: 12) {
                StatTile(value: "\(report.segmentsUnchanged)",
                         label: "unchanged",
                         color: .secondary)
                StatTile(value: "\(report.totalSegments)",
                         label: "total segments",
                         color: .secondary)
                StatTile(value: String(format: "-%.0f%%", report.wordReductionPct),
                         label: "word reduction",
                         color: .green)
            }
        }
    }

    private var rulesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rules applied")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            if report.rulesEnabled.isEmpty {
                Text("No cleanup rules were enabled.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(report.rulesEnabled, id: \.self) { rule in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                        Text(rule)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private var engineBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LLM")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                Text(report.providerLabel)
                    .font(.system(size: 12, weight: .medium))
                Text("·")
                    .foregroundColor(.secondary)
                Text(report.modelID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(report.batchCount) batch\(report.batchCount == 1 ? "" : "es")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "text.word.spacing")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                Text("Avg \(String(format: "%.1f", report.avgWordsBefore)) → \(String(format: "%.1f", report.avgWordsAfter)) words/segment")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var noChangeHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing was modified")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
            Text("Common reasons: the transcript already looked clean, no rules were enabled, or the LLM returned the input unchanged. If you expected changes, check the Settings → Debug log for hints.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineSpacing(2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.10))
        )
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.10))
        )
    }
}
