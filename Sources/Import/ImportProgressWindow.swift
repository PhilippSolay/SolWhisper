import AppKit
import SwiftUI

/// Small floating progress panel for file imports. One per active import.
/// Owner is `AppDelegate`, which keeps a reference until the import resolves.
@MainActor
final class ImportProgressWindow: NSWindowController, FileImportControllerDelegate {

    private let viewModel = ImportProgressViewModel()
    private let controller: FileImportController
    private let audioURL: URL
    private let onSuccess: (UUID) -> Void

    init(audioURL: URL, store: MeetingStore, onSuccess: @escaping (UUID) -> Void = { _ in }) {
        self.audioURL = audioURL
        self.controller = FileImportController(store: store)
        self.onSuccess = onSuccess
        viewModel.title = audioURL.lastPathComponent

        let view = ImportProgressView(model: viewModel,
                                      onCancel: { [weak controller] in controller?.cancel() })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Importing audio"
        window.setContentSize(NSSize(width: 420, height: 160))
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false

        super.init(window: window)
        controller.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func start() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.begin(audioURL: audioURL)
    }

    // MARK: - FileImportControllerDelegate

    func fileImport(_ controller: FileImportController,
                    didEnter phase: FileImportController.Phase) {
        // Once the import has resolved (success or failure), ignore late phase
        // updates. WhisperKit's progress callbacks are dispatched via separate
        // `Task { @MainActor }` calls and can land after `.done` has fired,
        // visually reverting the UI from "Done" back to "Transcribing…".
        if viewModel.completion != nil { return }

        switch phase {
        case .validating:
            viewModel.statusText = "Validating audio…"
            viewModel.progress = nil
        case .copying:
            viewModel.statusText = "Copying file into meeting folder…"
            viewModel.progress = nil
        case .loadingModel(let model, let alreadyDownloaded):
            viewModel.statusText = alreadyDownloaded
                ? "Loading WhisperKit model (\(model))…"
                : "Downloading WhisperKit model — first use of \(model) (~74 MB)…"
            viewModel.progress = nil
        case .warming(let audioSeconds):
            // Audio length is known up-front, but no progress fraction yet.
            // Surface duration so the user has *some* signal during the wait.
            let lengthHint = audioSeconds > 0
                ? " · \(formatTimestamp(audioSeconds)) of audio queued"
                : ""
            viewModel.statusText = "Preparing transcription engine\(lengthHint) — this can take 20–40s before progress shows"
            viewModel.progress = nil
        case .transcribing(let fraction, let audioSeconds):
            let pct = Int(fraction * 100)
            let positionLabel: String
            if audioSeconds > 0 {
                let position = audioSeconds * fraction
                positionLabel = " · \(formatTimestamp(position)) of \(formatTimestamp(audioSeconds))"
            } else {
                positionLabel = ""
            }
            viewModel.statusText = "Transcribing\(positionLabel) — \(pct)%"
            viewModel.progress = fraction
        case .writingOutputs:
            viewModel.statusText = "Writing transcript files…"
            viewModel.progress = 1.0
        case .cancelling:
            viewModel.statusText = "Cancelled"
            viewModel.completion = .failure
            window?.close()
        case .done(let meetingID, let folderURL, let segments, let audio):
            viewModel.statusText = "Done · \(segments) segment\(segments == 1 ? "" : "s") · \(formatTimestamp(audio)) audio"
            viewModel.progress = 1.0
            viewModel.completion = .success(folderURL: folderURL)
            onSuccess(meetingID)
        case .failed(let message):
            viewModel.statusText = message
            viewModel.progress = nil
            viewModel.completion = .failure
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

@MainActor
final class ImportProgressViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var statusText: String = "Starting…"
    @Published var progress: Double? = nil
    @Published var completion: Completion? = nil

    enum Completion: Equatable {
        case success(folderURL: URL)
        case failure
    }
}

/// Drops the window from the AppDelegate's `importWindows` dict when the user closes it.
@MainActor
final class ImportWindowCloser: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.onClose() }
    }
}

private struct ImportProgressView: View {
    @ObservedObject var model: ImportProgressViewModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if let p = model.progress {
                ProgressView(value: p)
            } else if model.completion == nil {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(model.statusText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                switch model.completion {
                case .success(let folderURL):
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                    }
                    Button("Close") { closeHostingWindow() }
                        .keyboardShortcut(.defaultAction)
                case .failure:
                    Button("Close") { closeHostingWindow() }
                        .keyboardShortcut(.defaultAction)
                case .none:
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: 160)
    }

    private func closeHostingWindow() {
        NSApp.keyWindow?.close()
    }
}
