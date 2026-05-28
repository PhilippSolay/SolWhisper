import SwiftUI

extension View {
    /// Adds a thin green stroke around the view when `done` is true. Used on
    /// the action-row buttons in `MeetingDetailView` to signal that the
    /// underlying step (transcribe / clean / diarize / summarize) has
    /// already been run for this meeting — distinct from the transient
    /// green "<Op> done" flash that fires right after completion.
    @ViewBuilder
    func completionOutline(_ done: Bool) -> some View {
        if done {
            self.overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.65), lineWidth: 1.5)
                    .padding(-1)
                    .allowsHitTesting(false)
            )
        } else {
            self
        }
    }
}
