import Foundation
import Combine

/// Serial queue for file imports. Every import entry point — in-window drop,
/// the upload panel, and Dock/Finder drops — funnels through here, and files
/// are processed strictly one at a time. Serial execution is both what the
/// user asked for ("one after another") and a correctness win: concurrent
/// imports would otherwise contend on the single shared WhisperKit instance.
///
/// The queue is the `FileImportControllerDelegate` for whichever item is
/// currently importing; its `@Published items` drive the inline detail-area UI.
@MainActor
final class ImportQueue: ObservableObject, FileImportControllerDelegate {

    /// Visible pipeline steps for one import, in order. `.integrating` is
    /// surfaced as "Send" in the tracker.
    static let pipelineSteps: [MeetingProcessingPhase] =
        [.transcribing, .cleaning, .diarizing, .summarizing, .integrating]

    enum Status: Equatable {
        case queued
        case active
        case done
        case failed(String)
        case cancelled
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let audioURL: URL
        var status: Status
        /// Current pipeline stage while `.active`.
        var stage: MeetingProcessingPhase
        /// 0…1 progress for the active stage (transcribe reports it; the LLM
        /// stages are indeterminate).
        var stageFraction: Double?
        /// Short human status line, e.g. "Transcribing · 1:23 of 4:56 — 45%".
        var detail: String
        /// Optional stages enabled when this item started, snapshotted so the
        /// tracker can render disabled ones as "skipped" rather than "pending".
        var enabledStages: Set<MeetingProcessingPhase>
        /// Populated on success.
        var meetingID: UUID?
        var segmentCount: Int
        /// True once this item has been included in an end-of-batch report, so
        /// incremental drops don't re-report already-surfaced outcomes.
        var reported: Bool = false

        var filename: String { audioURL.lastPathComponent }
    }

    /// End-of-batch outcome, surfaced to the owner as a pop-up (single file) or
    /// a log (many files).
    struct BatchReport {
        struct Failure { let name: String; let reason: String }
        var succeeded: [String]
        var failed: [Failure]
        var cancelled: [String]
    }

    @Published private(set) var items: [Item] = []

    /// Whether the detail area should present the queue. Set on enqueue,
    /// cleared when the user navigates to a meeting or clears the finished list.
    @Published var presentedInDetail: Bool = false

    /// Invoked when work is enqueued so the owner can surface the window.
    var onActivity: () -> Void = {}

    /// Invoked when the queue drains, carrying every outcome finished since the
    /// last drain. The owner turns it into a pop-up (single file) or log (many).
    var onBatchFinished: (BatchReport) -> Void = { _ in }

    private let store: MeetingStore
    private var current: FileImportController?
    private var currentItemID: UUID?

    init(store: MeetingStore) {
        self.store = store
    }

    // MARK: - Derived state (for the header + summary)

    /// 1-based position of the importing item, for "2 of 5".
    var activePosition: Int? {
        guard let idx = items.firstIndex(where: { $0.status == .active }) else { return nil }
        return idx + 1
    }
    var total: Int { items.count }
    var isProcessing: Bool { current != nil }
    var hasUnfinished: Bool { items.contains(where: isPending) }

    /// End-of-batch summary once everything has finished, e.g. "Imported 4 · 1 failed".
    var summaryLine: String? {
        guard !items.isEmpty, !hasUnfinished else { return nil }
        let done = items.filter { $0.status == .done }.count
        let failed = items.filter { if case .failed = $0.status { return true } else { return false } }.count
        let cancelled = items.filter { $0.status == .cancelled }.count
        var parts = ["Imported \(done)"]
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Public API

    /// Filters to supported audio, dedupes against files already queued or
    /// importing, appends the rest, and starts the pump. Returns how many were
    /// actually enqueued (0 means nothing supported / all duplicates).
    @discardableResult
    func enqueue(_ urls: [URL]) -> Int {
        var inFlight = Set(items.filter(isPending).map { $0.audioURL.standardizedFileURL })
        var addedSupported = 0
        var addedAny = false
        for url in urls {
            let standardized = url.standardizedFileURL
            if FileTranscriber.acceptedExtensions.contains(url.pathExtension.lowercased()) {
                guard !inFlight.contains(standardized) else { continue }   // dedupe within + across drops
                items.append(Item(id: UUID(),
                                  audioURL: url,
                                  status: .queued,
                                  stage: .transcribing,
                                  stageFraction: nil,
                                  detail: "Queued",
                                  enabledStages: [],
                                  meetingID: nil,
                                  segmentCount: 0))
                inFlight.insert(standardized)
                addedSupported += 1
                addedAny = true
            } else {
                // Surface the rejection as a failed row instead of dropping it
                // silently — it rides the same end-of-batch report as processing
                // failures (single → pop-up, many → part of the log).
                items.append(Item(id: UUID(),
                                  audioURL: url,
                                  status: .failed("Not a supported audio file"),
                                  stage: .transcribing,
                                  stageFraction: nil,
                                  detail: "Not a supported audio file",
                                  enabledStages: [],
                                  meetingID: nil,
                                  segmentCount: 0))
                addedAny = true
            }
        }
        guard addedAny else { return 0 }
        presentedInDetail = true
        onActivity()
        startNextIfIdle()
        // Nothing to process (only unsupported files) → report the rejections now.
        if current == nil { reportBatchIfDrained() }
        return addedSupported
    }

    /// Removes a queued item, or cancels it if it's the one importing.
    func cancel(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[idx].status {
        case .queued:  items.remove(at: idx)
        case .active:  current?.cancel()   // delegate maps → cancelled + advance
        default:       break
        }
    }

    /// Cancels the active import and drops everything still queued.
    func cancelAll() {
        items.removeAll { $0.status == .queued }
        current?.cancel()
    }

    /// Removes finished rows; dismisses the queue if nothing is left.
    func clearFinished() {
        items.removeAll { !isPending($0) }
        if items.isEmpty { presentedInDetail = false }
    }

    // MARK: - Serial pump

    private func startNextIfIdle() {
        guard current == nil,
              let idx = items.firstIndex(where: { $0.status == .queued }) else { return }
        items[idx].enabledStages = MeetingPostProcessor.enabledStages()
        items[idx].stage = .transcribing
        items[idx].stageFraction = nil
        items[idx].detail = "Starting…"
        items[idx].status = .active
        currentItemID = items[idx].id

        let controller = FileImportController(store: store)
        controller.delegate = self
        current = controller
        controller.begin(audioURL: items[idx].audioURL)
    }

    private func advance() {
        current = nil
        currentItemID = nil
        startNextIfIdle()
        if current == nil { reportBatchIfDrained() }
    }

    /// Once no work remains, report every finished-but-unreported item exactly
    /// once so incremental drops each get their own report.
    private func reportBatchIfDrained() {
        guard !hasUnfinished else { return }
        let finished = items.enumerated().filter { !$0.element.reported && !isPending($0.element) }
        guard !finished.isEmpty else { return }

        var succeeded: [String] = []
        var failed: [BatchReport.Failure] = []
        var cancelled: [String] = []
        for (idx, item) in finished {
            switch item.status {
            case .done:            succeeded.append(item.filename)
            case .failed(let msg): failed.append(.init(name: item.filename, reason: msg))
            case .cancelled:       cancelled.append(item.filename)
            default:               break
            }
            items[idx].reported = true
        }
        onBatchFinished(BatchReport(succeeded: succeeded, failed: failed, cancelled: cancelled))
    }

    private func isPending(_ item: Item) -> Bool {
        item.status == .queued || item.status == .active
    }

    // MARK: - FileImportControllerDelegate

    func fileImport(_ controller: FileImportController,
                    didEnter phase: FileImportController.Phase) {
        // Ignore stray callbacks from a controller we've already advanced past
        // — WhisperKit progress can land after the item resolved.
        guard controller === current,
              let id = currentItemID,
              let idx = items.firstIndex(where: { $0.id == id }) else { return }

        switch phase {
        case .validating:
            setStage(idx, .transcribing, detail: "Validating audio…")
        case .copying:
            setStage(idx, .transcribing, detail: "Copying file…")
        case .loadingModel(let model, let alreadyDownloaded):
            setStage(idx, .transcribing,
                     detail: alreadyDownloaded
                        ? "Loading model (\(model))…"
                        : "Downloading model \(model) — first use (~74 MB)…")
        case .warming(let audioSeconds):
            let hint = audioSeconds > 0 ? " · \(Self.clock(audioSeconds)) of audio" : ""
            setStage(idx, .transcribing,
                     detail: "Preparing engine\(hint) — 20–40s before progress")
        case .transcribing(let fraction, let audioSeconds):
            let pos = audioSeconds > 0
                ? " · \(Self.clock(audioSeconds * fraction)) of \(Self.clock(audioSeconds))"
                : ""
            items[idx].stage = .transcribing
            items[idx].stageFraction = fraction
            items[idx].detail = "Transcribing\(pos) — \(Int((fraction * 100).rounded()))%"
        case .cleaning:
            setStage(idx, .cleaning, detail: "Cleaning transcript…")
        case .diarizing:
            setStage(idx, .diarizing, detail: "Identifying speakers…")
        case .summarizing:
            setStage(idx, .summarizing, detail: "Summarizing…")
        case .sending:
            setStage(idx, .integrating, detail: "Sending to integrations…")
        case .cancelling:
            items[idx].status = .cancelled
            items[idx].detail = "Cancelled"
            advance()
        case .done(let meetingID, _, let segments, _):
            items[idx].status = .done
            items[idx].meetingID = meetingID
            items[idx].segmentCount = segments
            items[idx].detail = "Done · \(segments) segment\(segments == 1 ? "" : "s")"
            advance()
        case .failed(let message):
            // cancel() surfaces as .cancelling first; a genuine failure marks
            // the row and moves to the next file (continue-on-failure).
            if message == "Cancelled" {
                items[idx].status = .cancelled
                items[idx].detail = "Cancelled"
            } else {
                items[idx].status = .failed(message)
                items[idx].detail = message
            }
            advance()
        }
    }

    private func setStage(_ idx: Int, _ stage: MeetingProcessingPhase, detail: String) {
        items[idx].stage = stage
        items[idx].stageFraction = nil
        items[idx].detail = detail
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
