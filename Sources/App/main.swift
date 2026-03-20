import AppKit

// AppDelegate is @MainActor — use NSApplicationMain-style subclass
// so the delegate is created on the main actor at startup.
final class SolWhisperApplication: NSApplication {
    private let appDelegate = AppDelegate()

    override init() {
        super.init()
        delegate = appDelegate
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

_ = SolWhisperApplication.shared
NSApp.run()
