import AppKit

enum PasteManager {

    static func paste(text: String) {
        // Store original pasteboard content
        let pasteboard = NSPasteboard.general
        let originalContents = pasteboard.pasteboardItems?.compactMap { item -> (types: [NSPasteboard.PasteboardType], data: [(NSPasteboard.PasteboardType, Data)])? in
            let types = item.types
            let data = types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let d = item.data(forType: type) else { return nil }
                return (type, d)
            }
            return (types: types, data: data)
        }

        // Set transcribed text to pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V via AppleScript
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("PasteManager AppleScript error: \(error)")
            }
        }

        // Restore original pasteboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let originalContents = originalContents, !originalContents.isEmpty {
                pasteboard.clearContents()
                for item in originalContents {
                    let newItem = NSPasteboardItem()
                    for (type, data) in item.data {
                        newItem.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([newItem])
                }
            }
        }
    }
}
