import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Floating panel that displays OCR'd source text + its translation. Mirrors
/// the dismiss model of `SnipResultBubble` (click to paste, Esc to close,
/// observed ⌘V elsewhere, click-outside, idle timeout) so the two screen
/// features feel like siblings.
///
/// What's different from SnipResultBubble:
/// - 500 wide (vs 460), and grows vertically with content.
/// - Two text blocks stacked: source (read-only) on top, translation below.
/// - Header carries the auto-detected source tag (or override picker) and
///   a target-language picker. Changing the target re-translates in place.
/// - Two engines: Apple `Translation` framework on macOS 14.4+ (default),
///   else the LLM engine via `LLMResolver`. Picked once at present-time;
///   the user changes it in Settings → Translate.
///
/// The bubble always copies the *translated* text to `NSPasteboard` so
/// click-to-paste delivers the translation, not the original. The footer
/// hint makes that explicit so the user isn't surprised.
@MainActor
final class TranslateResultBubble {

    private let sourceText: String
    private let pasteTarget: NSRunningApplication?
    private let onDismiss: () -> Void

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var clickOutsideMonitor: Any?
    private var didDismiss = false
    /// The most recent successful translation. Nil until the first engine
    /// result lands. Used to gate click-to-paste so the footer's "click to
    /// paste translated" promise can't be broken by an early click while
    /// the translation is still in flight.
    private var latestTranslation: String?

    /// Idle dismiss timeout. A touch longer than SnipBubble's 8s because
    /// translation takes a moment and the user may still be reading.
    static var idleTimeoutSeconds: TimeInterval = 12

    init(sourceText: String,
         pasteTarget: NSRunningApplication?,
         onDismiss: @escaping () -> Void) {
        self.sourceText = sourceText
        self.pasteTarget = pasteTarget
        self.onDismiss = onDismiss
    }

    deinit {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Lifecycle

    func present() {
        let initialTarget = UserDefaults.standard.string(forKey: "translateTargetLanguage")
                         ?? TranslationLanguage.defaultTargetCode
        let detected = LanguageDetector.detect(sourceText)
        let engine = TranslationEngineKind.current

        let view = TranslateBubbleView(
            sourceText: sourceText,
            initialDetectedCode: detected?.code,
            initialDetectionConfidence: detected?.confidence ?? 0,
            initialTargetCode: initialTarget,
            engineKind: engine,
            onPasteAndClose: { [weak self] in self?.pasteAndDismiss() },
            onCopyTranslated: { [weak self] translated in
                self?.writeToPasteboard(translated)
            },
            onClose: { [weak self] in self?.dismiss(reason: .userClose) },
            onTargetChange: { code in
                UserDefaults.standard.set(code, forKey: "translateTargetLanguage")
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: TranslateBubbleView.bubbleSize)
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(origin: positionedOrigin(),
                                 size: TranslateBubbleView.bubbleSize),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.isFloatingPanel             = true
        p.level                       = .floating
        p.backgroundColor             = .clear
        p.isOpaque                    = false
        p.hasShadow                   = true
        p.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView                 = hosting
        p.alphaValue                  = 0
        self.panel = p

        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }

        installDismissalMonitors()
        startIdleTimer()
    }

    private func dismiss(reason: DismissReason) {
        guard !didDismiss else { return }
        didDismiss = true
        teardownMonitors()
        DebugLog.shared.log(icon: "🌐", label: "Translate bubble dismissed",
                            value: reason.rawValue)

        guard let panel else {
            onDismiss()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            // Hop to the main actor for the user's @MainActor onDismiss
            // callback — the completion handler runs on a Sendable boundary
            // even though, in practice, NSAnimationContext invokes us back
            // on the main thread.
            Task { @MainActor in self?.onDismiss() }
        })
    }

    private enum DismissReason: String {
        case userClose      = "user-close"
        case userPasted     = "user-pasted-here"
        case observedPasteV = "observed-CmdV"
        case esc            = "esc"
        case timeout        = "idle-timeout"
        case clickOutside   = "click-outside"
    }

    // MARK: - Paste action

    /// Pastes the latest translated text. Until the first translation
    /// completes, click-to-paste is a no-op (so we never paste source text
    /// when the footer promises translated text). `latestTranslation` is
    /// the single source of truth — we don't trust the pasteboard because
    /// another app could clobber it in the interim.
    private func pasteAndDismiss() {
        guard !didDismiss else { return }
        guard let translated = latestTranslation else {
            DebugLog.shared.log(icon: "🌐", label: "Translate paste ignored",
                                value: "no translation yet")
            return
        }
        let target = pasteTarget
        Task { @MainActor in
            self.panel?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await PasteManager.paste(text: translated, into: target)
            self.dismiss(reason: .userPasted)
        }
    }

    private func writeToPasteboard(_ text: String) {
        latestTranslation = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Position

    private func positionedOrigin() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                  ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSPoint(x: 200, y: 200)
        }
        let size = TranslateBubbleView.bubbleSize
        let centeredX = mouseLocation.x - size.width / 2
        let belowY = mouseLocation.y - size.height - 24
        let clampedX = min(max(centeredX, visible.minX + 8), visible.maxX - size.width - 8)
        let clampedY = max(belowY, visible.minY + 8)
        return NSPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Dismissal monitors

    private func installDismissalMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {  // Esc
                self.dismiss(reason: .esc)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {  // Return / numpad Return
                self.pasteAndDismiss()
                return nil
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let isV = event.keyCode == 9
            let cmdDown = event.modifierFlags.contains(.command)
            if isV && cmdDown {
                Task { @MainActor in self.dismiss(reason: .observedPasteV) }
            }
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.dismiss(reason: .clickOutside) }
        }
    }

    private func teardownMonitors() {
        if let m = globalKeyMonitor   { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor    { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m); clickOutsideMonitor = nil }
        dismissTimer?.invalidate(); dismissTimer = nil
    }

    private func startIdleTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeoutSeconds,
                                             repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(reason: .timeout) }
        }
    }
}

// MARK: - Engine selection

/// The two translation backends the bubble can dispatch to. The user picks
/// the default in Settings → Translate; the bubble reads that preference
/// once at present-time and doesn't switch mid-session.
enum TranslationEngineKind: String, Sendable, CaseIterable {
    case apple
    case llm

    static let userDefaultsKey = "translateEngine"

    /// Resolves the current preference. Falls back to `.apple` on macOS 15.0+
    /// and to `.llm` below (where the Apple framework's `TranslationSession`
    /// API isn't available).
    static var current: TranslationEngineKind {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey)
        if let raw, let kind = TranslationEngineKind(rawValue: raw) { return kind }
        if #available(macOS 15.0, *) {
            return .apple
        }
        return .llm
    }
}

// MARK: - SwiftUI view

/// Translation status drives the bottom block — spinner, translated text,
/// or inline error with retry. Kept inside the view since both engines feed
/// the same state machine.
private enum TranslateStatus: Equatable {
    case idle
    case translating
    case done(String)
    case error(String)
    case sameLanguage   // source matches target; we just echo the source
}

private struct TranslateBubbleView: View {

    let sourceText: String
    let initialDetectedCode: String?
    let initialDetectionConfidence: Double
    let initialTargetCode: String
    let engineKind: TranslationEngineKind
    let onPasteAndClose: () -> Void
    let onCopyTranslated: (String) -> Void
    let onClose: () -> Void
    let onTargetChange: (String) -> Void

    @State private var sourceLanguageCode: String?
    @State private var targetLanguageCode: String
    @State private var status: TranslateStatus = .idle
    /// Bumped whenever the user changes target language so the Apple
    /// `.translationTask` modifier re-fires with a fresh configuration.
    @State private var configurationToken: Int = 0
    /// LLM tasks are cooperatively cancelable; we drop stale ones when the
    /// user picks a new target before the current one finishes.
    @State private var llmTask: Task<Void, Never>?

    static let bubbleWidth:  CGFloat = 500
    static let bubbleHeight: CGFloat = 320
    static let cornerRadius: CGFloat = 18
    static let bubbleSize            = CGSize(width: bubbleWidth, height: bubbleHeight)

    init(sourceText: String,
         initialDetectedCode: String?,
         initialDetectionConfidence: Double,
         initialTargetCode: String,
         engineKind: TranslationEngineKind,
         onPasteAndClose: @escaping () -> Void,
         onCopyTranslated: @escaping (String) -> Void,
         onClose: @escaping () -> Void,
         onTargetChange: @escaping (String) -> Void) {
        self.sourceText = sourceText
        self.initialDetectedCode = initialDetectedCode
        self.initialDetectionConfidence = initialDetectionConfidence
        self.initialTargetCode = initialTargetCode
        self.engineKind = engineKind
        self.onPasteAndClose = onPasteAndClose
        self.onCopyTranslated = onCopyTranslated
        self.onClose = onClose
        self.onTargetChange = onTargetChange
        _sourceLanguageCode = State(initialValue: initialDetectedCode)
        _targetLanguageCode = State(initialValue: initialTargetCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            sourceBlock

            Divider().background(Color.white.opacity(0.08))

            translatedBlock

            footer
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: Self.bubbleWidth, height: Self.bubbleHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color(white: 0.10, opacity: 0.94))
        )
        .contentShape(Rectangle())
        .onTapGesture { onPasteAndClose() }
        .onAppear { kickoffTranslation() }
        .modifier(AppleTranslationModifier(
            engineKind: engineKind,
            sourceText: sourceText,
            sourceCode: sourceLanguageCode,
            targetCode: targetLanguageCode,
            token: configurationToken,
            onResult: handleEngineResult,
            onError: handleEngineError
        ))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundColor(.white.opacity(0.55))
                .font(.system(size: 11))

            sourceLanguageTag

            Image(systemName: "arrow.right")
                .foregroundColor(.white.opacity(0.4))
                .font(.system(size: 10))

            targetLanguagePicker

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var sourceLanguageTag: some View {
        // High-confidence detection renders as a fixed tag. Low confidence
        // or missing detection shows an override picker so the user can
        // correct mis-identified short captures.
        if initialDetectionConfidence >= LanguageDetector.confidenceThreshold,
           let code = sourceLanguageCode {
            Text(TranslationLanguage.named(code).label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08)))
        } else {
            Menu {
                Button("Auto-detect") { sourceLanguageCode = nil; bumpToken() }
                Divider()
                ForEach(TranslationLanguage.curated) { lang in
                    Button(lang.label) {
                        sourceLanguageCode = lang.code
                        bumpToken()
                    }
                }
            } label: {
                Text(sourceLanguageLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
    }

    private var sourceLanguageLabel: String {
        if let code = sourceLanguageCode {
            return TranslationLanguage.named(code).label.uppercased()
        }
        return "AUTO"
    }

    private var targetLanguagePicker: some View {
        Menu {
            ForEach(TranslationLanguage.curated) { lang in
                Button {
                    guard targetLanguageCode != lang.code else { return }
                    targetLanguageCode = lang.code
                    onTargetChange(lang.code)
                    bumpToken()
                } label: {
                    if lang.code == targetLanguageCode {
                        Label(lang.label, systemImage: "checkmark")
                    } else {
                        Text(lang.label)
                    }
                }
            }
        } label: {
            Text(TranslationLanguage.named(targetLanguageCode).label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
    }

    // MARK: - Text blocks

    private var sourceBlock: some View {
        ScrollView {
            Text(sourceText)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 110)
    }

    @ViewBuilder
    private var translatedBlock: some View {
        switch status {
        case .idle, .translating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                Text("Translating…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)

        case .done(let translated):
            ScrollView {
                Text(translated)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 130)

        case .sameLanguage:
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceText)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Source matches target — original copied")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(maxHeight: 130)

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red.opacity(0.85))
                    .multilineTextAlignment(.leading)
                Button {
                    bumpToken()
                } label: {
                    Text("Retry")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "doc.on.clipboard")
                .foregroundColor(.white.opacity(0.4))
                .font(.system(size: 10))
            Text("Translated · click to paste, ⌘V to use elsewhere")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(engineKind == .apple ? "On-device" : "LLM")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    // MARK: - Translation kickoff

    private func bumpToken() {
        llmTask?.cancel()
        configurationToken &+= 1
        kickoffTranslation()
    }

    private func kickoffTranslation() {
        let target = targetLanguageCode
        let source = sourceLanguageCode

        // Short-circuit when source confidently matches target.
        if let source, TranslationLanguage.sameLanguage(source, target) {
            status = .sameLanguage
            onCopyTranslated(sourceText)
            return
        }

        status = .translating

        switch engineKind {
        case .apple:
            // The Apple `.translationTask` modifier only attaches on macOS 15+.
            // If a user previously saved `.apple` in UserDefaults and is now
            // running an older OS (or downgraded), the modifier is a no-op
            // and the spinner would hang forever — fall through to LLM.
            if #available(macOS 15.0, *) {
                // `.translationTask` modifier picks this up via token change.
                break
            } else {
                runLLM(target: target, source: source)
            }
        case .llm:
            runLLM(target: target, source: source)
        }
    }

    private func runLLM(target: String, source: String?) {
        llmTask?.cancel()
        let text = sourceText
        // Token-match the result on completion. If the user picks a new
        // target language before the LLM responds, the inflight task is
        // cancelled — but Task cancellation is cooperative, so we also
        // verify the token hasn't moved before applying the result.
        let kickoffToken = configurationToken
        llmTask = Task { @MainActor in
            do {
                let engine = LLMTranslationEngine()
                let out = try await engine.translate(
                    text: text,
                    sourceCode: source,
                    targetCode: target
                )
                if Task.isCancelled { return }
                guard kickoffToken == configurationToken else {
                    DebugLog.shared.log(icon: "🌐", label: "Translate (LLM) stale result dropped",
                                        value: "token=\(kickoffToken) current=\(configurationToken)")
                    return
                }
                handleEngineResult(out.translated)
                DebugLog.shared.log(icon: "🌐", label: "Translate (LLM)",
                                    value: "\(out.providerLabel) \(out.modelID) · \(out.translated.count) chars\(out.truncated ? " · truncated" : "")")
            } catch {
                if Task.isCancelled { return }
                handleEngineError(error.localizedDescription)
                DebugLog.shared.log(icon: "🌐", label: "Translate (LLM) failed",
                                    value: error.localizedDescription, ok: false)
            }
        }
    }

    // MARK: - Engine callbacks

    private func handleEngineResult(_ translated: String) {
        status = .done(translated)
        onCopyTranslated(translated)
    }

    private func handleEngineError(_ message: String) {
        status = .error(message)
    }
}

// MARK: - Apple Translation modifier

/// Bridges Apple's SwiftUI-only `.translationTask` modifier into our state
/// machine. Applies only on macOS 14.4+ and when the user has picked the
/// Apple engine; otherwise the modifier is an identity no-op.
private struct AppleTranslationModifier: ViewModifier {
    let engineKind: TranslationEngineKind
    let sourceText: String
    let sourceCode: String?
    let targetCode: String
    let token: Int
    let onResult: (String) -> Void
    let onError: (String) -> Void

    func body(content: Content) -> some View {
        if engineKind == .apple, #available(macOS 15.0, *) {
            content.modifier(AppleTranslationModifierBody(
                sourceText: sourceText,
                sourceCode: sourceCode,
                targetCode: targetCode,
                token: token,
                onResult: onResult,
                onError: onError
            ))
        } else {
            content
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct AppleTranslationModifierBody: ViewModifier {
    let sourceText: String
    let sourceCode: String?
    let targetCode: String
    let token: Int
    let onResult: (String) -> Void
    let onError: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await runTranslation(session: session)
            }
            .onAppear { rebuildConfiguration() }
            .onChange(of: token) { rebuildConfiguration() }
    }

    private func rebuildConfiguration() {
        // Don't fire the framework when source and target match — the kickoff
        // logic in the parent view has already short-circuited to
        // `.sameLanguage` and we'd otherwise overwrite it with `.done`.
        if let sourceCode, TranslationLanguage.sameLanguage(sourceCode, targetCode) {
            configuration = nil
            return
        }
        let target = Locale.Language(identifier: targetCode)
        let source: Locale.Language? = sourceCode.map { Locale.Language(identifier: $0) }
        configuration = TranslationSession.Configuration(
            source: source,
            target: target
        )
    }

    private func runTranslation(session: TranslationSession) async {
        do {
            // Confirm the language pair is supported and downloaded. This
            // surfaces the system download prompt automatically on first run
            // for a given pair.
            try await session.prepareTranslation()
            let response = try await session.translate(sourceText)
            await MainActor.run {
                onResult(response.targetText)
            }
        } catch {
            // Apple's `TranslationError` cases are opaque on macOS 14.4 —
            // surface the localized description and let the user retry.
            await MainActor.run {
                onError(error.localizedDescription)
            }
        }
    }
}
#else
@available(macOS 15.0, *)
private struct AppleTranslationModifierBody: ViewModifier {
    let sourceText: String
    let sourceCode: String?
    let targetCode: String
    let token: Int
    let onResult: (String) -> Void
    let onError: (String) -> Void

    func body(content: Content) -> some View { content }
}
#endif
