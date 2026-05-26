import Foundation

/// Substeps of the post-recording pipeline. Published by `MeetingController`
/// so the detail view can show a multi-step progress indicator and the app
/// delegate can decide when to swap the pill for the Transcripts window.
///
/// Order matches the runPostProcessing() flow:
/// stitching → transcribing → cleaning → diarizing → summarizing → integrating.
/// `cleaning`, `diarizing`, `summarizing`, and `integrating` are conditional
/// on user toggles; the pipeline indicator renders skipped steps as muted.
enum MeetingProcessingPhase: String, Equatable, Sendable, CaseIterable {
    case stitching
    case transcribing
    case cleaning
    case diarizing
    case summarizing
    case integrating

    var label: String {
        switch self {
        case .stitching:    return "Stitching audio"
        case .transcribing: return "Transcribing"
        case .cleaning:     return "Cleaning"
        case .diarizing:    return "Diarizing"
        case .summarizing:  return "Summarizing"
        case .integrating:  return "Sending to integrations"
        }
    }

    var iconName: String {
        switch self {
        case .stitching:    return "waveform"
        case .transcribing: return "text.bubble"
        case .cleaning:     return "wand.and.sparkles"
        case .diarizing:    return "person.2.wave.2"
        case .summarizing:  return "sparkles"
        case .integrating:  return "paperplane"
        }
    }

    /// Phases shown in the pipeline indicator (stitching is internal plumbing
    /// — users care about the four visible stages).
    static let visibleSteps: [MeetingProcessingPhase] =
        [.transcribing, .cleaning, .diarizing, .summarizing]
}
