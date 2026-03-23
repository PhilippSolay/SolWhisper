import AppKit
import SwiftUI

class OverlayWindowController: NSObject {

    private var window: NSWindow?
    private let transcriptionController: TranscriptionController

    // Dimensions
    private let overlayWidth:  CGFloat = 520
    private let overlayHeight: CGFloat = 64

    init(transcriptionController: TranscriptionController) {
        self.transcriptionController = transcriptionController
        super.init()
    }

    // MARK: - Show / Hide

    func showOverlay() {
        if window == nil { createWindow() }
        window?.alphaValue = 0
        window?.orderFront(nil)
        animateIn()
    }

    func hideOverlay() {
        animateOut { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    // MARK: - Window creation

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let origin = NSPoint(
            x: sf.midX - overlayWidth / 2,
            y: sf.minY + 100
        )
        let frame = NSRect(origin: origin, size: CGSize(width: overlayWidth, height: overlayHeight))

        let panel = NSPanel(
            contentRect: frame,
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.isFloatingPanel          = true
        panel.level                    = .floating
        panel.backgroundColor          = .clear
        panel.isOpaque                 = false
        panel.hasShadow                = false   // we draw our own shadow in SwiftUI
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // ── Visual effect base (real system blur) ──────────────────────────
        let vev = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        vev.blendingMode  = .behindWindow
        vev.material      = .hudWindow
        vev.state         = .active
        vev.wantsLayer    = true
        vev.layer?.cornerRadius    = overlayHeight / 2
        vev.layer?.masksToBounds   = true

        // ── SwiftUI content on top ─────────────────────────────────────────
        let content = RecordingOverlayView(
            transcriptionController: transcriptionController,
            onStop:   { Task { @MainActor in (NSApp.delegate as? AppDelegate)?.stopRecording()   } },
            onCancel: { Task { @MainActor in (NSApp.delegate as? AppDelegate)?.cancelRecording() } }
        )

        let hosting = NSHostingView(rootView: content)
        hosting.frame = vev.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = .none
        vev.addSubview(hosting)

        panel.contentView = vev
        self.window = panel
    }

    // MARK: - Animation

    private func animateIn() {
        guard let window = window else { return }
        // Start slightly below + scaled down
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x,
                                      y: window.frame.origin.y - 10))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration          = 0.35
            ctx.timingFunction    = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1) // spring
            window.animator().alphaValue = 1
            window.animator().setFrameOrigin(NSPoint(x: window.frame.origin.x,
                                                     y: window.frame.origin.y + 10))
        }
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let window = window else { completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration       = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrameOrigin(NSPoint(x: window.frame.origin.x,
                                                     y: window.frame.origin.y - 6))
        }, completionHandler: completion)
    }
}
