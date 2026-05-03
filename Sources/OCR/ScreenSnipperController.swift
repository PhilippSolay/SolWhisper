import AppKit
import Combine
import Foundation
import Vision

/// Single-instance state machine for the OCR / "snip text" feature.
/// Owned by `AppDelegate`. Triggered by the snip hotkey or the tray menu.
///
/// State transitions:
///   idle → capturing → recognizing → displaying → idle
///
/// At each step, failures fall back to `.idle` after a one-line debug log.
@MainActor
final class ScreenSnipperController: ObservableObject {

    enum State: Equatable {
        case idle
        case capturing
        case recognizing
        case displaying
    }

    @Published private(set) var state: State = .idle

    /// The frontmost app at the moment `snip()` was triggered. We pass this
    /// to the result bubble's paste action so it lands in the right window
    /// even if the user clicks around between snip and paste.
    private var pasteTarget: NSRunningApplication?
    private var bubble: SnipResultBubble?

    func snip() {
        guard state == .idle else {
            DebugLog.shared.log(icon: "✂️", label: "Snip ignored",
                                value: "state=\(state)")
            return
        }
        // Snapshot focus BEFORE screencapture takes over.
        pasteTarget = NSWorkspace.shared.frontmostApplication
        DebugLog.shared.log(icon: "✂️", label: "Snip start",
                            value: "target=\(pasteTarget?.localizedName ?? "nil")")
        Task { await run() }
    }

    private func run() async {
        state = .capturing
        DebugLog.shared.log(icon: "✂️", label: "Snip capturing", value: "silent=\(silentCapture)")
        guard let result = await ScreenCapture.interactive(silent: silentCapture) else {
            DebugLog.shared.log(icon: "✂️", label: "Snip cancelled",
                                value: "screencapture returned no image (cancel or non-zero exit)",
                                ok: false)
            state = .idle
            return
        }
        DebugLog.shared.log(icon: "✂️", label: "Snip captured",
                            value: "image=\(result.imageURL.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: result.imageURL) }

        state = .recognizing
        let recognizer = TextRecognizer(
            recognitionLevel: recognitionLevelSetting,
            usesLanguageCorrection: usesLanguageCorrection,
            recognitionLanguages: recognitionLanguages,
            autoDetectLanguage: autoDetectLanguage
        )

        let observations: [LineObservation]
        do {
            observations = try await recognizer.recognize(result.imageURL)
            DebugLog.shared.log(icon: "✂️", label: "OCR observations",
                                value: "\(observations.count) lines")
        } catch {
            DebugLog.shared.log(icon: "✂️", label: "OCR failed",
                                value: "\(error)", ok: false)
            state = .idle
            return
        }

        let mode = lineBreakModeSetting
        let text = OCRPostProcessor.process(observations, mode: mode)
        guard !text.isEmpty else {
            DebugLog.shared.log(icon: "✂️", label: "OCR empty result",
                                value: "\(observations.count) raw lines but post-process produced empty text",
                                ok: false)
            state = .idle
            return
        }

        // Atomic write to clipboard so manual ⌘V works immediately.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        DebugLog.shared.log(icon: "✂️", label: "OCR done",
                            value: "\(text.count) chars · mode=\(mode.rawValue)")

        // Show the bubble.
        state = .displaying
        let target = pasteTarget
        let bubble = SnipResultBubble(
            text: text,
            pasteTarget: target,
            onDismiss: { [weak self] in
                self?.bubble = nil
                self?.state = .idle
                self?.pasteTarget = nil
            }
        )
        self.bubble = bubble
        bubble.present()
    }

    // MARK: - Settings shorthand

    private var lineBreakModeSetting: LineBreakMode {
        let raw = UserDefaults.standard.string(forKey: "ocrLineBreakMode") ?? "keep"
        return LineBreakMode(rawValue: raw) ?? .keep
    }

    private var recognitionLevelSetting: VNRequestTextRecognitionLevel {
        let raw = UserDefaults.standard.string(forKey: "ocrRecognitionLevel") ?? "accurate"
        return raw == "fast" ? .fast : .accurate
    }

    private var usesLanguageCorrection: Bool {
        // Default true if unset
        if UserDefaults.standard.object(forKey: "ocrUseLangCorrection") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ocrUseLangCorrection")
    }

    private var recognitionLanguages: [String] {
        let raw = UserDefaults.standard.string(forKey: "ocrRecognitionLanguages") ?? ""
        return raw.split(separator: ",").map(String.init)
    }

    private var autoDetectLanguage: Bool {
        UserDefaults.standard.bool(forKey: "ocrAutoDetectLanguage")
    }

    private var silentCapture: Bool {
        if UserDefaults.standard.object(forKey: "ocrSilentCapture") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ocrSilentCapture")
    }
}
