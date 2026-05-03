import Foundation
import AppKit

/// Scans the meetings root for sessions that have a `chunks/` folder but no
/// `chunks/done.flag`. Those represent recordings interrupted by a crash or
/// force-quit and the user should be offered the chance to recover them.
///
/// Recovery itself (stitching chunks → final WAV → re-running transcription)
/// is wired to the recovery dialog by `MeetingController.recoverSession(_:)`.
@MainActor
enum CrashRecovery {

    struct OrphanSession {
        let meeting: Meeting
        let chunksDirectory: URL
        let chunkCount: Int
    }

    /// Returns the list of orphan sessions in the store. Idempotent — safe to
    /// call repeatedly. Skips sessions whose meta is unparseable rather than
    /// throwing (we'd rather miss a recovery than crash on launch).
    static func scan(in store: MeetingStore) -> [OrphanSession] {
        var orphans: [OrphanSession] = []
        for meeting in store.meetings {
            let chunksDir = store.folderURL(for: meeting).appendingPathComponent("chunks")
            let doneFlag = chunksDir.appendingPathComponent("done.flag")
            let fm = FileManager.default
            guard fm.fileExists(atPath: chunksDir.path),
                  !fm.fileExists(atPath: doneFlag.path) else { continue }
            let count = chunkCount(at: chunksDir)
            guard count > 0 else { continue }
            orphans.append(OrphanSession(
                meeting: meeting,
                chunksDirectory: chunksDir,
                chunkCount: count
            ))
        }
        return orphans
    }

    /// Counts `chunk-NNNN-mic.wav` files. Used as a quick "is this worth
    /// recovering" signal in the dialog.
    static func chunkCount(at chunksDirectory: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: chunksDirectory,
                                                         includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("chunk-") && name.hasSuffix("-mic.wav")
        }.count
    }

    /// Presents a recovery dialog if there are orphans. Returns the orphans
    /// the user agreed to recover; the caller is responsible for actually
    /// running recovery.
    static func presentDialogIfNeeded(orphans: [OrphanSession]) -> [OrphanSession] {
        guard !orphans.isEmpty else { return [] }

        let alert = NSAlert()
        let count = orphans.count
        alert.messageText = "Recover unfinished meeting\(count == 1 ? "" : "s")?"
        alert.informativeText = orphans.enumerated().map { idx, o in
            "\(idx + 1). \(o.meeting.title) — \(o.chunkCount) chunk\(o.chunkCount == 1 ? "" : "s")"
        }.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Decide later")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:  return orphans
        case .alertSecondButtonReturn: return []          // discard handled by caller
        default:                        return []          // decide later
        }
    }
}
