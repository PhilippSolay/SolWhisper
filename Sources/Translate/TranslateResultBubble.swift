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
    /// When set, the bubble opens pre-selected to this target language instead
    /// of the shared `translateTargetLanguage`. Used by Voice Translate so it
    /// can honor its own default language.
    private let initialTargetOverride: String?

    private var panel: NSPanel?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// Observes `NSWindow.didMoveNotification` so we can persist the
    /// dragged position to UserDefaults — next open returns to that spot.
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var didDismiss = false
    /// The most recent successful translation. Nil until the first engine
    /// result lands. Used to gate click-to-paste so the footer's "click to
    /// paste translated" promise can't be broken by an early click while
    /// the translation is still in flight.
    private var latestTranslation: String?

    // The bubble used to auto-dismiss on idle timeout, click-outside, and
    // observed ⌘V. Per product call: it now only closes on the explicit X
    // button, Esc, ↩/click-to-paste-here, or a ⌘V into another app (i.e.
    // the user pasted the translation somewhere). Nothing else dismisses it,
    // and the window is freely draggable so it can be parked while the user
    // works.

    init(sourceText: String,
         pasteTarget: NSRunningApplication?,
         initialTargetOverride: String? = nil,
         onDismiss: @escaping () -> Void) {
        self.sourceText = sourceText
        self.pasteTarget = pasteTarget
        self.initialTargetOverride = initialTargetOverride
        self.onDismiss = onDismiss
    }

    deinit {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = moveObserver { NotificationCenter.default.removeObserver(m) }
        if let m = resizeObserver { NotificationCenter.default.removeObserver(m) }
    }

    // MARK: - Lifecycle

    func present() {
        let initialTarget = initialTargetOverride
                         ?? UserDefaults.standard.string(forKey: "translateTargetLanguage")
                         ?? TranslationLanguage.defaultTargetCode
        // Auto-detect the source language and pre-select it in the dropdown.
        // The user can still override via the menu — see `languageMenuPill`.
        let detected = LanguageDetector.detect(sourceText)
        if let detected {
            DebugLog.shared.log(icon: "🌐", label: "Translate source detected",
                                value: "\(detected.code) (conf \(String(format: "%.2f", detected.confidence)))")
        }
        let engine = TranslationEngineKind.current

        let view = TranslateBubbleView(
            sourceText: sourceText,
            initialDetectedCode: detected?.code,
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
        // Restore the user's last chosen size (resizable), else the default.
        let bubbleSize = rememberedSize() ?? TranslateBubbleView.bubbleSize
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: bubbleSize)
        hosting.autoresizingMask = [.width, .height]
        // The window drives the content size (via autoresizing), not the other
        // way around. Without this the panel briefly pops/resizes on first
        // layout before settling.
        hosting.sizingOptions = []

        let p = NSPanel(
            contentRect: NSRect(origin: positionedOrigin(size: bubbleSize),
                                 size: bubbleSize),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
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
        p.minSize                     = TranslateBubbleView.minBubbleSize
        p.maxSize                     = TranslateBubbleView.maxBubbleSize
        p.alphaValue                  = 0
        // Free-form dragging. `isMovableByWindowBackground` makes any
        // click-and-drag on the borderless panel reposition it; a plain
        // click without drag still passes through to SwiftUI's tap handler
        // (which pastes the translation), so the two gestures coexist.
        p.isMovable                   = true
        p.isMovableByWindowBackground = true
        self.panel = p

        // Persist the dragged origin every time the user moves the panel.
        // didMove fires after each drag completes, so we only write on
        // settled positions (not during a live drag).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.panel else { return }
            self?.saveOrigin(panel.frame.origin)
        }

        // Persist the size whenever the user resizes the panel, so the next open
        // reuses it (origin is saved separately on move).
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.panel else { return }
            self?.saveSize(panel.frame.size)
            self?.saveOrigin(panel.frame.origin)
        }

        // Order in while invisible, let SwiftUI complete its first layout pass,
        // then fade in on the next runloop tick — so any initial size/position
        // settle happens at alpha 0 and isn't seen as a jump.
        p.orderFront(nil)
        p.layoutIfNeeded()
        DispatchQueue.main.async { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 1
            }
        }

        installDismissalMonitors()
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

    /// UserDefaults keys for the persisted bubble position. Stored as two
    /// doubles so we don't have to deal with `NSPoint` archival quirks.
    private enum PositionKeys {
        static let originX = "translateBubbleOriginX"
        static let originY = "translateBubbleOriginY"
        static let width   = "translateBubbleWidth"
        static let height  = "translateBubbleHeight"
    }

    /// Returns the last user-chosen bubble size, clamped to the allowed range,
    /// or nil if the user has never resized it.
    private func rememberedSize() -> NSSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PositionKeys.width) != nil,
              defaults.object(forKey: PositionKeys.height) != nil else { return nil }
        let minS = TranslateBubbleView.minBubbleSize
        let maxS = TranslateBubbleView.maxBubbleSize
        let w = min(max(defaults.double(forKey: PositionKeys.width),
                        Double(minS.width)), Double(maxS.width))
        let h = min(max(defaults.double(forKey: PositionKeys.height),
                        Double(minS.height)), Double(maxS.height))
        return NSSize(width: w, height: h)
    }

    private func saveSize(_ size: NSSize) {
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width), forKey: PositionKeys.width)
        defaults.set(Double(size.height), forKey: PositionKeys.height)
    }

    /// Returns where the bubble should appear on present. Priority:
    /// 1. A previously remembered position (if it still fits on some screen)
    /// 2. Docked to the right edge of the screen the cursor is on
    /// 3. A fallback `(200, 200)` if the screen list is empty
    private func positionedOrigin(size: CGSize = TranslateBubbleView.bubbleSize) -> NSPoint {
        if let remembered = rememberedOriginIfVisible(size: size) {
            return remembered
        }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                  ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSPoint(x: 200, y: 200)
        }
        // Right-edge dock, vertically centered. 16pt inset from the screen
        // edge so the shadow doesn't get clipped by the bezel.
        let rightMargin: CGFloat = 16
        let x = visible.maxX - size.width - rightMargin
        let y = visible.midY - size.height / 2
        let clampedY = max(visible.minY + 8, min(y, visible.maxY - size.height - 8))
        return NSPoint(x: x, y: clampedY)
    }

    /// Reads the saved origin and returns it only when at least the
    /// majority of the bubble would still be on one of the user's current
    /// screens — protects against a display-config change leaving the
    /// bubble stranded off-screen.
    private func rememberedOriginIfVisible(size: CGSize) -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PositionKeys.originX) != nil,
              defaults.object(forKey: PositionKeys.originY) != nil else {
            return nil
        }
        let candidate = NSPoint(
            x: defaults.double(forKey: PositionKeys.originX),
            y: defaults.double(forKey: PositionKeys.originY)
        )
        let frame = NSRect(origin: candidate, size: size)
        let visible = NSScreen.screens.first { screen in
            screen.visibleFrame.intersects(frame)
        } != nil
        return visible ? candidate : nil
    }

    /// Persists the panel's current origin to UserDefaults. Called on every
    /// drag completion via `NSWindow.didMoveNotification` so the next open
    /// reuses the spot the user parked the bubble.
    private func saveOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: PositionKeys.originX)
        defaults.set(Double(origin.y), forKey: PositionKeys.originY)
    }

    // MARK: - Dismissal monitors

    private func installDismissalMonitors() {
        // Local monitor — fires when the bubble's panel is the key window.
        // Esc closes; Return pastes the translation into the previously
        // focused app and closes.
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

        // Global monitor — observes ⌘V in another app and treats that as
        // "the user pasted the translation somewhere", so we close. This is
        // one of the two sanctioned auto-dismiss paths; the other is the
        // explicit X / Esc / ↩ / click-bubble flow.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let isV = event.keyCode == 9
            let cmdDown = event.modifierFlags.contains(.command)
            if isV && cmdDown {
                Task { @MainActor in self.dismiss(reason: .observedPasteV) }
            }
        }
    }

    private func teardownMonitors() {
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m); localKeyMonitor  = nil }
        if let m = moveObserver { NotificationCenter.default.removeObserver(m); moveObserver = nil }
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

    static let bubbleWidth:  CGFloat = 560
    static let bubbleHeight: CGFloat = 500
    static let cornerRadius: CGFloat = 18
    static let bubbleSize            = CGSize(width: bubbleWidth, height: bubbleHeight)
    static let minBubbleSize         = NSSize(width: 360, height: 260)
    static let maxBubbleSize         = NSSize(width: 1200, height: 1000)

    init(sourceText: String,
         initialDetectedCode: String?,
         initialTargetCode: String,
         engineKind: TranslationEngineKind,
         onPasteAndClose: @escaping () -> Void,
         onCopyTranslated: @escaping (String) -> Void,
         onClose: @escaping () -> Void,
         onTargetChange: @escaping (String) -> Void) {
        self.sourceText = sourceText
        self.initialDetectedCode = initialDetectedCode
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
        .frame(minWidth: Self.minBubbleSize.width, maxWidth: .infinity,
               minHeight: Self.minBubbleSize.height, maxHeight: .infinity)
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
        HStack(spacing: 10) {
            sourceLanguageTag

            Image(systemName: "arrow.right")
                .foregroundColor(.white.opacity(0.4))
                .font(.system(size: 11))

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

    /// Source language pill. Always a dropdown (no fixed-text branch), even
    /// for high-confidence detections — the user can always override what
    /// the detector picked. The detected language is pre-selected via
    /// `sourceLanguageCode` set at init.
    private var sourceLanguageTag: some View {
        languageMenuPill(
            currentLabel: sourceLanguageLabel,
            currentCode:  sourceLanguageCode,
            includesAutoDetect: true,
            onSelect: { code in
                sourceLanguageCode = code
                bumpToken()
            }
        )
    }

    private var sourceLanguageLabel: String {
        if let code = sourceLanguageCode {
            return TranslationLanguage.named(code).label.uppercased()
        }
        return "AUTO"
    }

    private var targetLanguagePicker: some View {
        languageMenuPill(
            currentLabel: TranslationLanguage.named(targetLanguageCode).label.uppercased(),
            currentCode:  targetLanguageCode,
            includesAutoDetect: false,
            onSelect: { code in
                guard let code, targetLanguageCode != code else { return }
                targetLanguageCode = code
                onTargetChange(code)
                bumpToken()
            }
        )
    }

    /// Shared menu-as-pill renderer for the source and target. Uses
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` so the background pill
    /// we draw on the label actually renders (the `.borderlessButton` style
    /// silently strips backgrounds and forces its own chevron position) and
    /// `.menuIndicator(.hidden)` so only our explicitly-placed chevron shows
    /// — to the *right* of the label, matching system menus.
    @ViewBuilder
    private func languageMenuPill(
        currentLabel: String,
        currentCode: String?,
        includesAutoDetect: Bool,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            if includesAutoDetect {
                Button("Auto-detect") { onSelect(nil) }
                Divider()
            }
            ForEach(TranslationLanguage.curated) { lang in
                Button {
                    onSelect(lang.code)
                } label: {
                    if lang.code == currentCode {
                        Label(lang.label, systemImage: "checkmark")
                    } else {
                        Text(lang.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.10))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
        .frame(maxHeight: .infinity)
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
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

        case .sameLanguage:
            VStack(alignment: .leading, spacing: 4) {
                Text(sourceText)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Source matches target — original copied")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)

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
        let normalized = Self.normalizeOutput(translated)
        status = .done(normalized)
        onCopyTranslated(normalized)
    }

    private func handleEngineError(_ message: String) {
        status = .error(message)
    }

    /// Translators (especially Apple's framework on `\n`-separated input)
    /// sometimes re-render paragraph breaks as runs of two or more newlines,
    /// producing visibly double-spaced output. Collapse any run of 3+ blank
    /// lines back to a single blank line so the translation matches the
    /// source's vertical density.
    fileprivate static func normalizeOutput(_ text: String) -> String {
        var s = text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        // Trim trailing whitespace per line so a single accidental space at
        // line-end doesn't keep collapse from matching.
        s = s.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
