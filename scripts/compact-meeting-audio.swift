// One-off ops tool: re-encode legacy float32 WAV meeting recordings to mono
// AAC .m4a and (with --delete) remove the WAVs. Mirrors the in-app
// `MeetingAudioCompaction` migration but runnable from the command line.
//
// Reuses the shipping encoder — compile alongside it:
//   swiftc Sources/Meeting/AudioFileTranscoder.swift scripts/compact-meeting-audio.swift -o /tmp/swcompact
//   /tmp/swcompact "<meetings-root>"            # dry run (writes nothing permanent)
//   /tmp/swcompact "<meetings-root>" --delete   # convert + delete WAVs
//
// Safety: a WAV is deleted only after its .m4a is written and verified to match
// the source duration. Empty/stub WAVs are skipped.

import Foundation
import AVFoundation

func audioDuration(_ url: URL) -> Double {
    guard let f = try? AVAudioFile(forReading: url) else { return 0 }
    let r = f.processingFormat.sampleRate
    return r > 0 ? Double(f.length) / r : 0
}

func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

@main
struct CompactMeetingAudio {
  static func main() async {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: compact <meetings-root> [--delete]\n".utf8)); exit(2)
    }
    let root = URL(fileURLWithPath: args[1], isDirectory: true)
    let doDelete = args.contains("--delete")
    let bitRate = 128_000
    let fm = FileManager.default

    let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.hasDirectoryPath }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var converted = 0, failed = 0, skipped = 0
    var freed: Int64 = 0

    for folder in folders {
        let wavs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" && $0.lastPathComponent.hasPrefix("audio") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for wav in wavs {
            let rel = "\(folder.lastPathComponent)/\(wav.lastPathComponent)"
            let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
            let wavSize = fileSize(wav)
            let srcDur = audioDuration(wav)
            if srcDur <= 0 { print("SKIP  \(rel)  (empty, \(wavSize / 1000) KB)"); skipped += 1; continue }

            do {
                try await AudioFileTranscoder.toMonoAAC(source: wav, dest: m4a, bitRate: bitRate)
                let outDur = audioDuration(m4a)
                guard outDur >= srcDur * 0.95 else {
                    try? fm.removeItem(at: m4a)
                    print("BADV  \(rel)  duration \(Int(srcDur))s -> \(Int(outDur))s (kept WAV)")
                    failed += 1; continue
                }
                let m4aSize = fileSize(m4a)
                freed += max(0, wavSize - m4aSize)
                converted += 1
                if doDelete {
                    try fm.removeItem(at: wav)
                    print("OK    \(rel)  \(wavSize / 1_000_000)MB -> \(m4aSize / 1_000_000)MB  \(Int(outDur))s")
                } else {
                    try? fm.removeItem(at: m4a)   // dry run leaves no trace
                    print("DRY   \(rel)  \(wavSize / 1_000_000)MB -> \(m4aSize / 1_000_000)MB  \(Int(outDur))s")
                }
            } catch {
                try? fm.removeItem(at: m4a)
                print("FAIL  \(rel)  \(error)")
                failed += 1
            }
        }
    }

    print("=== converted=\(converted)  failed=\(failed)  skipped=\(skipped)  freed≈\(freed / 1_000_000)MB  delete=\(doDelete) ===")
  }
}
