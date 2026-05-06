import AppKit
import Combine
import SwiftUI

@MainActor
class OverlayWindowController: NSObject {

    private(set) var phaseState = OverlayPhaseState()

    private var panel: NSPanel?
    private var transcriptPanel: NSPanel?
    private var transcriptCancellable: AnyCancellable?
    private let transcriptionController: TranscriptionController
    private let onStop:   () -> Void
    private let onCancel: () -> Void
    private let onPause:  () -> Void

    // Persisted position keys — stored per screen-count scenario
    private static let posXKey = "overlayPositionX"
    private static let posYKey = "overlayPositionY"

    /// Returns a scenario key suffix based on the current screen count (e.g. "_1", "_2")
    private var scenarioSuffix: String { "_\(NSScreen.screens.count)" }
    private var scenarioPosXKey: String { Self.posXKey + scenarioSuffix }
    private var scenarioPosYKey: String { Self.posYKey + scenarioSuffix }

    // Design sizes (match RecordingOverlayView)
    private let circleSize: CGFloat = RecordingOverlayView.circleSize   // 56
    private let pillWidth:  CGFloat = RecordingOverlayView.pillWidth    // 120
    private let pillHeight: CGFloat = RecordingOverlayView.pillHeight   // 48
    private let hoverWidth: CGFloat = RecordingOverlayView.hoverWidth   // 200

    /// When false, the live transcript bubble below the pill is suppressed.
    /// Meeting recordings turn this off — meetings don't drive live partials,
    /// and any stale text from a prior dictation would flash up otherwise.
    private let showsLiveTranscript: Bool

    init(transcriptionController: TranscriptionController,
         onStop:   @escaping () -> Void,
         onCancel: @escaping () -> Void,
         onPause:  @escaping () -> Void,
         showsLiveTranscript: Bool = true) {
        self.transcriptionController = transcriptionController
        self.onStop   = onStop
        self.onCancel = onCancel
        self.onPause  = onPause
        self.showsLiveTranscript = showsLiveTranscript
        super.init()

        phaseState.onAccept = { [weak self] in self?.onStop() }
        phaseState.onCancel = { [weak self] in self?.onCancel() }
        phaseState.onResume = { [weak self] in self?.onPause() }  // toggle

        // React to live transcript / phase changes for the transcript bubble
        transcriptCancellable = Publishers.CombineLatest(
            transcriptionController.$liveTranscript,
            phaseState.$phase
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] text, phase in
            self?.updateTranscriptBubble(text: text, phase: phase)
        }
    }

    // MARK: - Public API

    func showOverlay() {
        if panel == nil { createPanel() }

        // Reset to circle phase
        phaseState.phase = .circle
        resetToCircle()

        panel?.alphaValue = 0
        panel?.orderFront(nil)
        animateIn()

        // After 50ms → expand to pill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.expandToPill()
        }
    }

    private var isHiding = false

    func hideOverlay() {
        guard !isHiding else { return }
        isHiding = true
        hideTranscriptBubble()
        animateOut { [weak self] in
            self?.panel?.orderOut(nil)
            self?.isHiding = false
        }
    }

    /// Immediately remove the panel with no animation — prevents it from
    /// intercepting focus or keyboard events during paste.
    func forceHide() {
        isHiding = false
        savePosition()
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        hideTranscriptBubble()
    }

    /// Toggle between listening and paused phases
    func togglePausePhase() {
        if phaseState.phase == .paused {
            phaseState.phase = .listening
        } else if phaseState.phase == .listening {
            phaseState.phase = .paused
        }
    }

    /// Switch to processing dots (called after user accepts)
    func showProcessing() {
        phaseState.phase = .processing
        hideTranscriptBubble()
        // Shrink back to pill width if hovering expanded it
        guard let panel = panel else { return }
        let newW = pillWidth
        let newH = pillHeight
        let newX = panel.frame.midX - newW / 2
        let newY = panel.frame.midY - newH / 2
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(
                NSRect(x: newX, y: newY, width: newW, height: newH),
                display: true
            )
        }
    }

    // MARK: - Panel creation

    private func createPanel() {
        let origin = savedOrigin()
        let p = NSPanel(
            contentRect: NSRect(origin: origin,
                                size: CGSize(width: circleSize, height: circleSize)),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.isFloatingPanel             = true
        p.level                       = .floating
        p.backgroundColor             = .clear
        p.isOpaque                    = false
        p.hasShadow                   = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = RecordingOverlayView(
            transcriptionController: transcriptionController,
            phaseState: phaseState
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame            = NSRect(origin: .zero, size: CGSize(width: circleSize, height: circleSize))
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        // Observe window moves to persist position
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: p
        )

        self.panel = p
    }

    deinit {
        if let panel { NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel) }
    }

    // MARK: - Phase transitions

    /// Animate circle → pill
    private func expandToPill() {
        guard let panel = panel else { return }

        let newW = pillWidth
        let newH = pillHeight
        let newX = panel.frame.midX - newW / 2
        let newY = panel.frame.midY - newH / 2

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
            panel.animator().setFrame(
                NSRect(x: newX, y: newY, width: newW, height: newH),
                display: true
            )
        }

        // Flip phase to listening after spring starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                self?.phaseState.phase = .listening
            }
        }
    }

    // MARK: - Position persistence

    private func savedOrigin() -> NSPoint {
        let defaults = UserDefaults.standard

        // Try scenario-specific position first (e.g. "overlayPositionX_2" for 2 monitors)
        var candidate: NSPoint?
        if defaults.object(forKey: scenarioPosXKey) != nil {
            candidate = NSPoint(
                x: defaults.double(forKey: scenarioPosXKey),
                y: defaults.double(forKey: scenarioPosYKey)
            )
        } else if defaults.object(forKey: Self.posXKey) != nil {
            // Fall back to legacy non-scenario key
            candidate = NSPoint(
                x: defaults.double(forKey: Self.posXKey),
                y: defaults.double(forKey: Self.posYKey)
            )
        }

        // Validate: is the candidate visible on any current screen?
        if let pt = candidate {
            let testRect = NSRect(origin: pt, size: CGSize(width: circleSize, height: circleSize))
            let onScreen = NSScreen.screens.contains { screen in
                screen.visibleFrame.intersects(testRect)
            }
            if onScreen { return pt }
        }

        // Default: top center of main screen
        let sf = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: sf.midX - circleSize / 2, y: sf.maxY - circleSize - 20)
    }

    @objc private func windowDidMove(_ note: Notification) {
        savePosition()
        repositionTranscriptBubble()
    }

    private func savePosition() {
        guard let panel = panel else { return }
        let x = Double(panel.frame.origin.x)
        let y = Double(panel.frame.origin.y)
        // Save to both scenario-specific and legacy keys
        UserDefaults.standard.set(x, forKey: scenarioPosXKey)
        UserDefaults.standard.set(y, forKey: scenarioPosYKey)
        UserDefaults.standard.set(x, forKey: Self.posXKey)
        UserDefaults.standard.set(y, forKey: Self.posYKey)
    }

    // MARK: - Helpers

    private func resetToCircle() {
        guard let panel = panel else { return }
        let origin = savedOrigin()
        panel.setFrame(NSRect(origin: origin,
                              size: CGSize(width: circleSize, height: circleSize)),
                       display: false)
    }

    // MARK: - Animation

    private func animateIn() {
        guard let panel = panel else { return }
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x,
                                     y: panel.frame.origin.y - 8))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(
                NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + 8)
            )
        }
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let panel = panel else { completion(); return }
        savePosition()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration       = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(
                NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y - 6)
            )
        }, completionHandler: completion)
    }

    // MARK: - Transcript Bubble (live transcript display)

    private func updateTranscriptBubble(text: String, phase: OverlayPhaseState.Phase) {
        let enabled = UserDefaults.standard.bool(forKey: "showLiveTranscript")
        let shouldShow = enabled
            && showsLiveTranscript
            && !text.isEmpty
            && (phase == .listening || phase == .paused)

        if shouldShow {
            if transcriptPanel == nil { createTranscriptPanel() }
            repositionTranscriptBubble()
            if transcriptPanel?.isVisible == false {
                transcriptPanel?.alphaValue = 0
                transcriptPanel?.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    transcriptPanel?.animator().alphaValue = 1
                }
            }
        } else {
            hideTranscriptBubble()
        }
    }

    private func hideTranscriptBubble() {
        guard let p = transcriptPanel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in
            p?.orderOut(nil)
        })
    }

    private func createTranscriptPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: TranscriptBubbleView.bubbleWidth,
                                height: TranscriptBubbleView.minHeight),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        p.isFloatingPanel    = true
        p.level              = .floating
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = true
        p.ignoresMouseEvents = true   // pill panel handles all interaction
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = TranscriptBubbleView(transcriptionController: transcriptionController)
        let hosting = NSHostingView(rootView: content)
        hosting.frame            = NSRect(origin: .zero, size: CGSize(width: TranscriptBubbleView.bubbleWidth, height: TranscriptBubbleView.minHeight))
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        self.transcriptPanel = p
    }

    private func repositionTranscriptBubble() {
        guard let pill = panel, let bubble = transcriptPanel else { return }
        let bw = TranscriptBubbleView.bubbleWidth
        let bh = bubble.frame.height > 0 ? bubble.frame.height : TranscriptBubbleView.minHeight
        let gap: CGFloat = 8
        let x = pill.frame.midX - bw / 2
        let y = pill.frame.minY - gap - bh
        bubble.setFrame(NSRect(x: x, y: y, width: bw, height: bh), display: true)
    }
}
