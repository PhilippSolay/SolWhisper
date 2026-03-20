import AppKit
import SwiftUI

class OverlayWindowController: NSObject {

    private var window: NSWindow?
    private let transcriptionController: TranscriptionController

    init(transcriptionController: TranscriptionController) {
        self.transcriptionController = transcriptionController
        super.init()
    }

    func showOverlay() {
        if window == nil {
            createWindow()
        }
        // orderFront only — don't activate SolWhisper or steal focus from the user's app
        window?.orderFront(nil)
        animateIn()
    }

    func hideOverlay() {
        animateOut { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    private func createWindow() {
        let overlayWidth: CGFloat = 560
        let overlayHeight: CGFloat = 120

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        // Position near bottom-center of screen
        let x = screenFrame.midX - overlayWidth / 2
        let y = screenFrame.minY + 120

        let windowFrame = NSRect(x: x, y: y, width: overlayWidth, height: overlayHeight)

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlayView = RecordingOverlayView(
            transcriptionController: transcriptionController,
            onStop: {
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.stopRecording()
                }
            },
            onCancel: {
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.cancelRecording()
                }
            }
        )

        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(origin: .zero, size: windowFrame.size)
        panel.contentView = hostingView

        // ESC key handling
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // ESC
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.cancelRecording()
                }
                return nil
            }
            return event
        }

        self.window = panel
    }

    private func animateIn() {
        guard let window = window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            window.animator().alphaValue = 1
        }
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let window = window else {
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        }, completionHandler: completion)
    }
}
