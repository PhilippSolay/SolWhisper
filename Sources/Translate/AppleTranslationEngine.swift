import Foundation

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

/// Translation engine error with a user-facing message.
enum AppleTranslationError: Error, LocalizedError {
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timedOut:
            return "Apple translation timed out. Switch to the AI model engine in Settings → Voice Translate."
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
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .floating
        // The view's `.translationTask`/`.onAppear` only run once the window is
        // part of the window list. Order it in (it is transparent + off-screen,
        // so invisible) and keep it parked far off any display.
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
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

/// 1×1 transparent SwiftUI view whose only job is to carry `.translationTask`.
@available(macOS 15.0, *)
private struct HeadlessTranslationView: View {
    let sourceText: String
    let sourceCode: String?
    let targetCode: String
    let onResult: (String) -> Void
    let onError: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                do {
                    // Surfaces the system download prompt for the pair on first
                    // use, then performs the on-device translation.
                    try await session.prepareTranslation()
                    let response = try await session.translate(sourceText)
                    onResult(response.targetText)
                } catch {
                    onError(error.localizedDescription)
                }
            }
            .onAppear {
                let target = Locale.Language(identifier: targetCode)
                let source = sourceCode.map { Locale.Language(identifier: $0) }
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
    }
}
#endif
