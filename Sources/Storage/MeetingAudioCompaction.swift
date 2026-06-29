import Foundation
import AVFoundation

/// One-time migration: re-encodes legacy float32 WAV meeting recordings
/// (`audio.wav`, `audio_mic.wav`, `audio_system.wav`) to **mono AAC 128k
/// `.m4a`** — matching what new recordings now write — then deletes the WAV
/// originals. Reclaims the bulk of the Meetings folder for pre-`.m4a` sessions.
///
/// No relinking is needed: audio is resolved by scanning `audio.*` in each
/// meeting folder (`MeetingStore.audioFileURL`), so dropping the `.m4a` in
/// place of the `.wav` *is* the relink.
///
/// Safety: a WAV is deleted ONLY after its `.m4a` is written, re-read, and
/// confirmed to match the source duration. Idempotent + crash-safe — a partial
/// run just re-encodes the leftovers next launch (the bitrate-honoring encoder
/// overwrites any partial `.m4a`).
enum MeetingAudioCompaction {

    private static let doneKey = "meetingAudioCompactionV1Done"

    struct Summary: Sendable {
        var converted = 0
        var failed = 0
        var reclaimedBytes: Int64 = 0
    }

    /// Runs the compaction once (gated by `doneKey`). Heavy I/O is dispatched
    /// off the main actor; the gate is set after the pass so it never re-runs
    /// the expensive scan, while failed files keep their WAV for a manual retry.
    @MainActor
    static func runIfNeeded(meetingStore: MeetingStore) {
        // Never run under XCTest — the test host launches the app, and a
        // destructive re-encode of the real Meetings folder must not be a
        // side effect of running the suite.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let folders = meetingStore.meetings.map { meetingStore.folderURL(for: $0) }
        guard !folders.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)   // fresh install — nothing to do
            return
        }

        let bitRate = MeetingController.archiveBitRate
        Task.detached(priority: .utility) {
            let summary = await compact(folders: folders, bitRate: bitRate)
            await MainActor.run {
                UserDefaults.standard.set(true, forKey: doneKey)
                DebugLog.shared.log(
                    icon: "🗜", label: "Audio compaction",
                    value: "converted \(summary.converted) · freed \(summary.reclaimedBytes / 1_000_000) MB · failed \(summary.failed)",
                    ok: summary.failed == 0)
            }
        }
    }

    /// Re-encodes every `audio*.wav` under each folder. Returns aggregate stats.
    static func compact(folders: [URL], bitRate: Int) async -> Summary {
        let fm = FileManager.default
        var summary = Summary()

        for folder in folders {
            let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let wavs = entries.filter {
                $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent.hasPrefix("audio")
            }
            for wav in wavs {
                let outcome = await convert(wavURL: wav, bitRate: bitRate)
                if outcome.converted {
                    summary.converted += 1
                    summary.reclaimedBytes += outcome.reclaimedBytes
                } else {
                    summary.failed += 1
                }
            }
        }
        return summary
    }

    /// Converts one WAV → sibling `.m4a` (mono AAC), verifies the output matches
    /// the source duration, then deletes the WAV. The WAV is preserved on ANY
    /// failure (the only copy of the recording is never dropped blind).
    static func convert(wavURL: URL, bitRate: Int) async -> (converted: Bool, reclaimedBytes: Int64) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: wavURL.path) else { return (false, 0) }
        let m4aURL = wavURL.deletingPathExtension().appendingPathExtension("m4a")

        let srcDuration = audioDuration(wavURL)
        guard srcDuration > 0 else { return (false, 0) }   // empty/stub WAV — skip

        do {
            try await AudioFileTranscoder.toMonoAAC(source: wavURL, dest: m4aURL, bitRate: bitRate)

            // Verify before deleting the only copy of the source.
            let outDuration = audioDuration(m4aURL)
            guard outDuration >= srcDuration * 0.95 else {
                try? fm.removeItem(at: m4aURL)   // bad/truncated encode — keep the WAV
                return (false, 0)
            }

            let wavSize = fileSize(wavURL, fm)
            let m4aSize = fileSize(m4aURL, fm)
            try fm.removeItem(at: wavURL)
            return (true, max(0, wavSize - m4aSize))
        } catch {
            try? fm.removeItem(at: m4aURL)   // clean any partial output; keep the WAV
            return (false, 0)
        }
    }

    private static func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    private static func fileSize(_ url: URL, _ fm: FileManager) -> Int64 {
        ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
