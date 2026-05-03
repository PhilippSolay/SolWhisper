import AppKit
import SwiftUI

/// Floating panel showing the OCR'd text. Visually modeled on the live
/// dictation transcript bubble (same dark rounded rect + corner radius) so
/// it feels native to the app.
///
/// Dismissal — five paths, whichever fires first:
///   1. Click bubble / press ↩  → paste into previously-focused app + close
///   2. Press Esc               → close (clipboard keeps the text)
///   3. Detected ⌘V into another app → close (text was just pasted)
///   4. 8-second idle timeout   → close
///   5. Click outside the panel → close
@MainActor
final class SnipResultBubble {

    private let text: String
    private let pasteTarget: NSRunningApplication?
    private let onDismiss: () -> Void

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var clickOutsideMonitor: Any?
    private var didDismiss = false

    /// Idle dismiss after N seconds. Tunable; ships at 8 s.
    static var idleTimeoutSeconds: TimeInterval = 8

    init(text: String,
         pasteTarget: NSRunningApplication?,
         onDismiss: @escaping () -> Void) {
        self.text = text
        self.pasteTarget = pasteTarget
        self.onDismiss = onDismiss
    }

    deinit {
        // Best-effort sync cleanup — `present` always sets monitors before
        // returning and `dismiss(...)` clears them. This is the
        // "deallocated mid-flight" safety net.
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickOutsideMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Lifecycle

    func present() {
        let view = SnipBubbleView(
            text: text,
            onPasteAndClose: { [weak self] in self?.pasteAndDismiss() },
            onClose:         { [weak self] in self?.dismiss(reason: .userClose) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: SnipBubbleView.bubbleSize)
        hosting.autoresizingMask = [.width, .height]

        let p = NSPanel(
            contentRect: NSRect(origin: positionedOrigin(),
                                 size: SnipBubbleView.bubbleSize),
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
        DebugLog.shared.log(icon: "✂️", label: "Snip bubble dismissed",
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
            self?.onDismiss()
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

    private func pasteAndDismiss() {
        guard !didDismiss else { return }
        Task { @MainActor in
            // Hide the bubble first so it doesn't catch the synthesized ⌘V.
            self.panel?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 80_000_000)
            await PasteManager.paste(text: self.text, into: self.pasteTarget)
            self.dismiss(reason: .userPasted)
        }
    }

    // MARK: - Position

    private func positionedOrigin() -> NSPoint {
        // Anchor to the screen the cursor is on; place the bubble centered
        // horizontally, just below the cursor (offset for visual breathing
        // room). Falls back to main-screen center if no screen matches.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                  ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            return NSPoint(x: 200, y: 200)
        }
        let size = SnipBubbleView.bubbleSize
        let centeredX = mouseLocation.x - size.width / 2
        let belowY = mouseLocation.y - size.height - 24
        let clampedX = min(max(centeredX, visible.minX + 8), visible.maxX - size.width - 8)
        let clampedY = max(belowY, visible.minY + 8)
        return NSPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Dismissal monitors

    private func installDismissalMonitors() {
        // Esc + ↩ when the bubble is the key window.
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

        // ⌘V observed in any other app while our bubble is up — means the
        // user just pasted our text elsewhere, so we close.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let isV = event.keyCode == 9      // ANSI V
            let cmdDown = event.modifierFlags.contains(.command)
            if isV && cmdDown {
                Task { @MainActor in self.dismiss(reason: .observedPasteV) }
            }
        }

        // Click outside the panel → dismiss.
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

// MARK: - SwiftUI view

private struct SnipBubbleView: View {
    let text: String
    let onPasteAndClose: () -> Void
    let onClose: () -> Void

    static let bubbleWidth: CGFloat   = 460
    static let bubbleHeight: CGFloat  = 160
    static let cornerRadius: CGFloat  = 18
    static let bubbleSize             = CGSize(width: bubbleWidth, height: bubbleHeight)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.dashed.and.paperclip")
                    .foregroundColor(.white.opacity(0.55))
                    .font(.system(size: 11))
                Text("Snipped text · click to paste, ⌘V to use elsewhere")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
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
    }
}
