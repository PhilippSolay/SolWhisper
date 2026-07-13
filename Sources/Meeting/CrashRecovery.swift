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
        let fm = FileManager.default
        for meeting in store.meetings {
            // Imports are recovered separately (see `interruptedImports`). They
            // have no chunks and the recording-recovery pipeline would
            // transcribe absent `audio_mic.m4a` → write an empty transcript and
            // mark the import "complete", discarding it. Never route an import
            // through here.
            guard meeting.source == .recording else { continue }
            let folder = store.folderURL(for: meeting)

            // A completed meeting always has a transcript.json (written at the
            // end of post-processing). If it's present, this meeting finished —
            // skip it. Keying recovery off the transcript (not `done.flag`) is
            // what lets us catch a crash/force-quit that happened DURING
            // post-processing, not only during recording: done.flag is written
            // when recording stops, well before the multi-minute transcribe
            // phase, so a crash mid-transcribe used to leave a permanently
            // empty, unrecoverable meeting.
            let transcript = folder.appendingPathComponent("transcript.json")
            if fm.fileExists(atPath: transcript.path) { continue }

            // Recoverable if either the raw chunks survive (crash during
            // recording) or the stitched audio survives (crash after stitch,
            // during transcribe — chunks already deleted).
            let chunksDir = folder.appendingPathComponent("chunks")
            let count = chunkCount(at: chunksDir)
            let hasChunks = fm.fileExists(atPath: chunksDir.path) && count > 0
            let hasStitchedAudio = fm.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("audio_mic.m4a").path)
            guard hasChunks || hasStitchedAudio else { continue }

            orphans.append(OrphanSession(
                meeting: meeting,
                chunksDirectory: chunksDir,
                chunkCount: count
            ))
        }
        return orphans
    }

    /// An import that was interrupted (crash/quit) after its audio was copied
    /// into the meeting folder but before `transcript.json` was written. The
    /// copied `audio.<ext>` is a complete, valid file, so recovery just
    /// re-runs the import on it (see AppDelegate) rather than leaving a blank
    /// meeting card that never transcribes.
    struct InterruptedImport {
        let meeting: Meeting
        let audioURL: URL
    }

    /// Finds imports with copied audio but no transcript. Idempotent.
    static func interruptedImports(in store: MeetingStore) -> [InterruptedImport] {
        let fm = FileManager.default
        var result: [InterruptedImport] = []
        for meeting in store.meetings where meeting.source == .import {
            let folder = store.folderURL(for: meeting)
            if fm.fileExists(atPath: folder.appendingPathComponent("transcript.json").path) {
                continue
            }
            // The import copy is `audio.<ext>` (mp3/m4a/wav/flac/…). Exclude the
            // recording-pipeline artifacts (`audio_mic`/`audio_system`).
            guard let entries = try? fm.contentsOfDirectory(at: folder,
                                                            includingPropertiesForKeys: nil) else { continue }
            let audio = entries.first { url in
                let name = url.deletingPathExtension().lastPathComponent
                return name == "audio" && url.pathExtension.lowercased() != "json"
            }
            if let audio { result.append(InterruptedImport(meeting: meeting, audioURL: audio)) }
        }
        return result
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
            let detail = o.chunkCount > 0
                ? "\(o.chunkCount) chunk\(o.chunkCount == 1 ? "" : "s")"
                : "interrupted while processing"
            return "\(idx + 1). \(o.meeting.title) — \(detail)"
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
