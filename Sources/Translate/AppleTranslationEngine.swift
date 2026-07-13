import Foundation

/// Translation engine error with a user-facing message. Lives outside the
/// `canImport(Translation)` guard so error handling (and its tests) compile
/// on every OS.
enum AppleTranslationError: Error, LocalizedError {
    case failed(String)
    case timedOut
    /// The pack for this language is being downloaded in Settings → Languages.
    case needsDownload(String)
    /// Apple's translator will never support this language (e.g. Farsi) and
    /// no AI model is configured to take over.
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timedOut:
            return "Apple translation timed out. Switch to the AI model engine in Settings → Voice Translate."
        case .needsDownload(let language):
            return "The \(language) language pack is downloading in Settings → Languages. Try again once it shows Installed."
        case .unsupportedLanguage(let language):
            return "Apple's translator doesn't support \(language). Add an AI model in Settings → Models (or switch the engine in Settings → Voice Translate) to translate it."
        }
    }
}

#if canImport(Translation)
import AppKit
import SwiftUI
import Translation

/// Headless runner for Apple's on-device `TranslationSession`.
///
/// Apple exposes `TranslationSession` only through the SwiftUI `.translationTask`
/// modifier — there is no way to create a session programmatically. To translate
/// without showing the bubble we host a 1×1, off-screen, fully transparent
/// SwiftUI view that carries the modifier, bridge its single result back through
/// a continuation, then tear the host down. `prepareTranslation()` surfaces the
/// system language-pack download prompt on first use of a pair, exactly like the
/// visible bubble.
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationEngine: TranslationEngine {

    func translate(text: String, sourceCode: String?, targetCode: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        // Source == target: nothing to translate (and the framework errors).
        if let sourceCode, TranslationLanguage.sameLanguage(sourceCode, targetCode) {
            return text
        }

        // Pre-flight the pair so a missing pack never ambushes the user with
        // the system download sheet over the floating "Translating…" card:
        //   needsDownload → deep-link Settings → Languages (download visible
        //                   there, with per-language status) and bail with an
        //                   actionable message;
        //   unsupported   → Apple will never offer it (e.g. Farsi) — the AI
        //                   model engine takes over when one is configured.
        let label = TranslationLanguage.named(targetCode).label
        let target = Locale.Language(identifier: targetCode)
        let source = Locale.Language(
            identifier: sourceCode ?? Locale.current.language.languageCode?.identifier ?? "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            break
        case .supported:
            // `.supported` = a pack is missing, but NOT necessarily the target's.
            // Translating an uninstalled non-English source INTO installed English
            // reports `.supported` because the SOURCE pack is absent — queue that,
            // not the target (which would deep-link a useless en→en download).
            let missing = await ApplePackProbe.codeToDownload(source: sourceCode, target: targetCode)
            let missingLabel = TranslationLanguage.named(missing).label
            DebugLog.shared.log(icon: "🌍", label: "Language pack missing — opening Settings → Languages",
                                value: missing, ok: false)
            SettingsDeepLink.open(.languages, downloadLanguage: missing)
            throw AppleTranslationError.needsDownload(missingLabel)
        case .unsupported:
            if LLMResolver.resolve(.translation) != nil {
                DebugLog.shared.log(icon: "🌍", label: "Apple can't translate this language — using AI model",
                                    value: targetCode)
                return try await LLMVoiceTranslationEngine().translate(
                    text: trimmed, sourceCode: sourceCode, targetCode: targetCode)
            }
            throw AppleTranslationError.unsupportedLanguage(label)
        @unknown default:
            break   // let the framework try; worst case it errors as before
        }

        return try await withCheckedThrowingContinuation { continuation in
            let host = HeadlessTranslationHost(
                sourceText: trimmed,
                sourceCode: sourceCode,
                targetCode: targetCode,
                continuation: continuation
            )
            host.start()
        }
    }
}

/// Owns the off-screen window for a single translation and guarantees the
/// continuation resumes exactly once (success, error, or timeout).
@available(macOS 15.0, *)
@MainActor
private final class HeadlessTranslationHost {

    /// Safety net: if the SwiftUI lifecycle never fires (e.g. the off-screen
    /// host is culled) we fail rather than hang the caller forever.
    private static let timeout: Duration = .seconds(30)

    private let sourceText: String
    private let sourceCode: String?
    private let targetCode: String
    private var continuation: CheckedContinuation<String, Error>?
    private var window: NSWindow?
    private var didFinish = false

    init(sourceText: String,
         sourceCode: String?,
         targetCode: String,
         continuation: CheckedContinuation<String, Error>) {
        self.sourceText = sourceText
        self.sourceCode = sourceCode
        self.targetCode = targetCode
        self.continuation = continuation
    }

    func start() {
        let view = HeadlessTranslationView(
            sourceText: sourceText,
            sourceCode: sourceCode,
            targetCode: targetCode,
            onResult: { [weak self] text in self?.finish(.success(text)) },
            onError: { [weak self] message in
                self?.finish(.failure(AppleTranslationError.failed(message)))
            }
        )
        // The window must be a REAL, visible, on-screen window. Two reasons:
        // (1) SwiftUI only runs `.onAppear`/`.translationTask` for a view that
        //     actually lays out — a hidden/zero-alpha window never does, so the
        //     translation silently hangs. (2) The first translation of a given
        //     language pair shows a system pack-download confirmation sheet; it
        //     needs a visible window to attach to and be clicked. We show a small
        //     "Translating…" card, centered, and tear it down when done.
        let size = NSSize(width: 230, height: 84)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.midX - size.width / 2,
                             y: screen.midY - size.height / 2)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient]
        window.orderFrontRegardless()
        self.window = window

        Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            self?.finish(.failure(AppleTranslationError.timedOut))
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard !didFinish else { return }
        didFinish = true
        window?.orderOut(nil)
        window = nil
        let cont = continuation
        continuation = nil
        switch result {
        case .success(let text):  cont?.resume(returning: text)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}

/// Small visible "Translating…" card that carries `.translationTask`. Being a
/// real rendered view is what makes the translation task run and lets the
/// first-use pack-download sheet attach.
@available(macOS 15.0, *)
private struct HeadlessTranslationView: View {
    let sourceText: String
    let sourceCode: String?
    let targetCode: String
    let onResult: (String) -> Void
    let onError: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?

    private var targetLabel: String { TranslationLanguage.named(targetCode).label }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Translating to \(targetLabel)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .translationTask(configuration) { session in
            DebugLog.shared.log(icon: "🌍", label: "VT-DIAG apple", value: "task fired, preparing", ok: false)
            do {
                // Surfaces the system download sheet for the pair on first use,
                // then performs the on-device translation.
                try await session.prepareTranslation()
                DebugLog.shared.log(icon: "🌍", label: "VT-DIAG apple", value: "prepared, translating", ok: false)
                let response = try await session.translate(sourceText)
                DebugLog.shared.log(icon: "🌍", label: "VT-DIAG apple", value: "translated len=\(response.targetText.count)", ok: false)
                onResult(response.targetText)
            } catch {
                DebugLog.shared.log(icon: "🌍", label: "VT-DIAG apple", value: "threw: \(error.localizedDescription)", ok: false)
                onError(error.localizedDescription)
            }
        }
        .onAppear {
            DebugLog.shared.log(icon: "🌍", label: "VT-DIAG apple", value: "view onAppear, setting config", ok: false)
            let target = Locale.Language(identifier: targetCode)
            let source = sourceCode.map { Locale.Language(identifier: $0) }
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}
#endif
