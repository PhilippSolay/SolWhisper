import AppKit
import Combine
import Foundation
import Vision

/// Single-instance state machine for the "Translate from screen" feature.
/// Mirrors `ScreenSnipperController` so the two screen-text features share
/// the same shape and feel.
///
/// State transitions:
///   idle → capturing → recognizing → displaying → idle
///
/// The bubble itself runs the translation step (because Apple's Translation
/// framework is SwiftUI-only) — this controller stops at "give the bubble
/// the OCR'd text" and the bubble takes over.
@MainActor
final class TranslationController: ObservableObject {

    enum State: Equatable {
        case idle
        case capturing
        case recognizing
        case displaying
    }

    @Published private(set) var state: State = .idle

    private var pasteTarget: NSRunningApplication?
    private var bubble: TranslateResultBubble?

    func translate() {
        guard state == .idle else {
            DebugLog.shared.log(icon: "🌐", label: "Translate ignored",
                                value: "state=\(state)")
            return
        }
        pasteTarget = NSWorkspace.shared.frontmostApplication
        DebugLog.shared.log(icon: "🌐", label: "Translate start",
                            value: "target=\(pasteTarget?.localizedName ?? "nil") engine=\(TranslationEngineKind.current.rawValue)")
        Task { await run() }
    }

    private func run() async {
        state = .capturing
        guard let result = await ScreenCapture.interactive(silent: silentCapture) else {
            DebugLog.shared.log(icon: "🌐", label: "Translate cancelled",
                                value: "screencapture returned no image",
                                ok: false)
            state = .idle
            return
        }
        DebugLog.shared.log(icon: "🌐", label: "Translate captured",
                            value: "image=\(result.imageURL.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: result.imageURL) }

        state = .recognizing
        // For translate we always auto-detect — the user's OCR-recognition
        // language preference may be pinned to a single language, but for
        // a translate snip we want Vision to be permissive across scripts.
        let recognizer = TextRecognizer(
            recognitionLevel: recognitionLevelSetting,
            usesLanguageCorrection: usesLanguageCorrection,
            recognitionLanguages: [],
            autoDetectLanguage: true
        )

        let observations: [LineObservation]
        do {
            observations = try await recognizer.recognize(result.imageURL)
            DebugLog.shared.log(icon: "🌐", label: "Translate OCR",
                                value: "\(observations.count) lines")
        } catch {
            DebugLog.shared.log(icon: "🌐", label: "Translate OCR failed",
                                value: "\(error)", ok: false)
            state = .idle
            return
        }

        // Always use `.remove` for translate — wrapped lines within a
        // paragraph get joined into a single sentence so the translator
        // sees coherent input (and doesn't emit per-line output with
        // double-spaced paragraph breaks). The user's OCR line-break
        // preference still applies to Text Snap; this is translate-specific.
        let text = OCRPostProcessor.process(observations, mode: .remove)
        guard !text.isEmpty else {
            DebugLog.shared.log(icon: "🌐", label: "Translate empty",
                                value: "\(observations.count) raw lines but post-process produced empty text",
                                ok: false)
            state = .idle
            return
        }

        state = .displaying
        let target = pasteTarget
        let bubble = TranslateResultBubble(
            sourceText: text,
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

    private var recognitionLevelSetting: VNRequestTextRecognitionLevel {
        let raw = UserDefaults.standard.string(forKey: "ocrRecognitionLevel") ?? "accurate"
        return raw == "fast" ? .fast : .accurate
    }

    private var usesLanguageCorrection: Bool {
        if UserDefaults.standard.object(forKey: "ocrUseLangCorrection") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ocrUseLangCorrection")
    }

    private var silentCapture: Bool {
        if UserDefaults.standard.object(forKey: "ocrSilentCapture") == nil { return true }
        return UserDefaults.standard.bool(forKey: "ocrSilentCapture")
    }
}
