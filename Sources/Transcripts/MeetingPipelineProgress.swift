import SwiftUI

/// Horizontal step tracker for the post-recording pipeline:
/// Transcribe → Clean → Diarize → Summarize. Renders each step's state
/// (pending / running / done / skipped) so the user can tell at a glance
/// what's happening and how far it's gotten.
///
/// State is composed from two inputs:
/// - The shared `MeetingController.processingPhase` (when *this* meeting
///   is the one currently being post-processed by the controller).
/// - Local manual-action flags (`retranscribing`, `cleaning`, `diarizing`,
///   `summarizing`) for re-runs invoked from the detail view itself.
struct MeetingPipelineProgress: View {

    enum StepStatus: Equatable { case pending, running, done, skipped, failed }

    struct Step: Identifiable {
        let id: MeetingProcessingPhase
        let label: String
        let icon: String
        var status: StepStatus
        /// 0…1 progress within this step. Optional — when present and the
        /// step is `.running`, the step view shows a small percentage
        /// caption under the label. Used today by transcribe (averaged
        /// across mic + system channels via WhisperKit's KVO progress).
        var fraction: Double? = nil
    }

    let steps: [Step]
    let totalElapsed: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    stepView(step)
                    if idx < steps.count - 1 {
                        connector(after: step)
                    }
                }
            }
            if let totalElapsed {
                Text("Elapsed \(formatElapsed(totalElapsed))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func stepView(_ step: Step) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(fillColor(step.status))
                    .frame(width: 28, height: 28)
                Circle()
                    .stroke(strokeColor(step.status), lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                if step.status == .running {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: iconName(step))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(iconColor(step.status))
                }
            }
            Text(step.label)
                .font(.system(size: 10, weight: status(step.status, .running) ? .semibold : .regular))
                .foregroundColor(labelColor(step.status))
                .lineLimit(1)
            if step.status == .running, let fraction = step.fraction {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func connector(after step: Step) -> some View {
        Rectangle()
            .fill(step.status == .done ? Color.green.opacity(0.55) : Color.secondary.opacity(0.25))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)
    }

    private func iconName(_ step: Step) -> String {
        switch step.status {
        case .done:    return "checkmark"
        case .skipped: return "minus"
        case .failed:  return "exclamationmark"
        default:       return step.icon
        }
    }

    private func fillColor(_ s: StepStatus) -> Color {
        switch s {
        case .done:    return .green.opacity(0.18)
        case .running: return .accentColor.opacity(0.18)
        case .failed:  return .red.opacity(0.18)
        case .skipped: return .secondary.opacity(0.08)
        case .pending: return .secondary.opacity(0.10)
        }
    }
    private func strokeColor(_ s: StepStatus) -> Color {
        switch s {
        case .done:    return .green.opacity(0.65)
        case .running: return .accentColor.opacity(0.65)
        case .failed:  return .red.opacity(0.65)
        case .skipped: return .secondary.opacity(0.30)
        case .pending: return .secondary.opacity(0.35)
        }
    }
    private func iconColor(_ s: StepStatus) -> Color {
        switch s {
        case .done:    return .green
        case .running: return .accentColor
        case .failed:  return .red
        case .skipped: return .secondary
        case .pending: return .secondary
        }
    }
    private func labelColor(_ s: StepStatus) -> Color {
        switch s {
        case .done, .running: return .primary
        default: return .secondary
        }
    }

    private func status(_ a: StepStatus, _ b: StepStatus) -> Bool { a == b }

    private func formatElapsed(_ s: TimeInterval) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60, r = Int(s) % 60
        return "\(m)m\(r)s"
    }
}
