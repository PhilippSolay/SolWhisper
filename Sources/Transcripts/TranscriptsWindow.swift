import AppKit
import SwiftUI

/// Owns the Transcripts NSWindow and keeps it alive across hide/show cycles.
/// Created lazily by AppDelegate the first time the user opens the window.
@MainActor
final class TranscriptsWindowController: NSWindowController {

    private let store: MeetingStore
    private let onUpload: () -> Void

    init(store: MeetingStore, onUpload: @escaping () -> Void) {
        self.store = store
        self.onUpload = onUpload

        let view = TranscriptsRootView(store: store, onUpload: onUpload)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Transcripts"
        window.toolbar = nil
        window.setContentSize(NSSize(width: 880, height: 560))
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Brings the window to the front and reloads the meeting list from disk
    /// so any meetings that arrived since the last open appear.
    func openAndReload() {
        try? store.loadAll()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
