import AppKit
import SwiftUI

/// External selection model for the Transcripts window — held by the window
/// controller, observed by the SwiftUI root view. Lets non-SwiftUI callers
/// (AppDelegate, MeetingController) drive what's selected without rebuilding
/// the hosting view.
@MainActor
final class TranscriptsSelection: ObservableObject {
    @Published var selection: UUID? = nil
}

/// Owns the Transcripts NSWindow and keeps it alive across hide/show cycles.
/// Created lazily by AppDelegate the first time the user opens the window.
@MainActor
final class TranscriptsWindowController: NSWindowController {

    private let store: MeetingStore
    private let onUpload: () -> Void
    let selectionModel = TranscriptsSelection()
    private let meetingController: MeetingController
    private let importQueue: ImportQueue

    init(store: MeetingStore,
         onUpload: @escaping () -> Void,
         meetingController: MeetingController,
         importQueue: ImportQueue) {
        self.store = store
        self.onUpload = onUpload
        self.meetingController = meetingController
        self.importQueue = importQueue

        let view = TranscriptsRootView(store: store,
                                       onUpload: onUpload,
                                       selectionModel: selectionModel)
            .environmentObject(meetingController)
            .environmentObject(importQueue)
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

    /// Opens the window (reloading if needed) and selects the given meeting.
    /// Used by the post-recording handoff so the user lands directly on the
    /// just-finished call with its pipeline indicator visible.
    func openAndSelect(meetingID: UUID) {
        openAndReload()
        selectionModel.selection = meetingID
    }
}
