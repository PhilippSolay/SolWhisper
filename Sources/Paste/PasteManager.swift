import AppKit

enum PasteManager {

    static func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // Save original pasteboard so we can restore it after paste
        let saved: [(NSPasteboard.PasteboardType, Data)] = pasteboard.pasteboardItems?.flatMap { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        } ?? []

        // Put transcribed text on pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate ⌘V via CGEvent — works with Accessibility permission,
        // fires into whatever app currently owns the key focus.
        let src = CGEventSource(stateID: .hidSystemState)

        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Restore original pasteboard after the paste has been processed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !saved.isEmpty else { return }
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            pasteboard.writeObjects([item])
        }
    }
}
