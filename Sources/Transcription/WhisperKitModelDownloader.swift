import Foundation
import Combine

/// Owns in-flight WhisperKit model downloads, keyed by model ID.
///
/// Download progress used to live in `WhisperKitModelPicker`'s `@State`, but
/// `SettingsView` rebuilds the detail pane on every sidebar switch — so
/// navigating away mid-download destroyed the progress UI while the download
/// task kept running orphaned. Coming back, the picker saw the half-written
/// variant folder and showed "✓ available offline" for an unfinished model.
///
/// Progress lives here instead: both pickers (dictation + meetings) observe
/// the same instance, re-attach to live downloads after navigation, and the
/// "✓" only appears once `downloadModel` actually returned and the artifact
/// check in `isModelDownloaded` passes.
@MainActor
final class WhisperKitModelDownloader: ObservableObject {

    static let shared = WhisperKitModelDownloader()

    /// Fraction complete per in-flight model ID; absent = not downloading.
    @Published private(set) var progress: [String: Double] = [:]
    /// Last failure message per model ID; cleared when a retry starts.
    @Published private(set) var lastError: [String: String] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    func isDownloading(_ model: String) -> Bool {
        progress[model] != nil
    }

    /// Starts downloading `model` unless one is already in flight — both
    /// settings pickers share this object, so double-clicks and
    /// dictation/meetings overlap dedupe here instead of racing the same
    /// destination folder.
    func download(_ model: String) {
        guard tasks[model] == nil else { return }
        progress[model] = 0
        lastError[model] = nil
        DebugLog.shared.log(icon: "🟣", label: "WhisperKit model download start",
                            value: model)

        tasks[model] = Task {
            let watch = Stopwatch()
            do {
                _ = try await WhisperKitClient.downloadModel(model) { fraction in
                    Task { @MainActor in
                        // Ignore late callbacks after finish/cancel.
                        if self.progress[model] != nil {
                            self.progress[model] = fraction
                        }
                    }
                }
                // HubApi.snapshot returns the *partial* folder instead of
                // throwing when its task is cancelled — don't report success.
                if Task.isCancelled {
                    lastError[model] = "Download was interrupted before it finished."
                    DebugLog.shared.log(icon: "🟣", label: "WhisperKit model download cancelled",
                                        value: model, ok: false)
                } else {
                    DebugLog.shared.log(icon: "🟣", label: "WhisperKit model download done",
                                        value: model, ms: watch.elapsed)
                }
            } catch {
                lastError[model] = error.localizedDescription
                DebugLog.shared.log(icon: "🟣", label: "WhisperKit model download failed",
                                    value: "\(model): \(error.localizedDescription)", ok: false)
            }
            progress[model] = nil
            tasks[model] = nil
        }
    }
}
