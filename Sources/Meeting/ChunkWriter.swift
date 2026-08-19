import Foundation
import AVFoundation

/// Writes mic + system audio to per-channel WAV chunks in
/// `<meetingFolder>/chunks/`. Files rotate every `chunkSeconds` (default 30 s).
///
/// File names follow the spec from plans/MEETING-FEATURES-PLAN.md §2:
///   - `chunk-NNNN-mic.wav`
///   - `chunk-NNNN-sys.wav`
///   - `chunk-NNNN.metadata.json`
///   - `done.flag`  ← written only on `finalize()`. Crash recovery uses this
///                    as the canonical "clean stop" signal.
///
/// Atomic writes: each chunk file is written to `.tmp` and renamed on close.
/// All disk I/O is `actor`-isolated so we don't block the audio thread.
actor ChunkWriter {

    let chunkSeconds: TimeInterval
    let chunkDirectory: URL
    let micFormat: AVAudioFormat
    let systemFormat: AVAudioFormat

    private var chunkIndex = 0
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var micFramesInChunk: AVAudioFrameCount = 0
    private var systemFramesInChunk: AVAudioFrameCount = 0
    private var micFramesPerChunk: AVAudioFrameCount = 0
    private var systemFramesPerChunk: AVAudioFrameCount = 0

    private var startedAt: Date?
    private var finalized = false

    init(chunkDirectory: URL,
         chunkSeconds: TimeInterval = 30,
         micFormat: AVAudioFormat,
         systemFormat: AVAudioFormat) throws {
        self.chunkDirectory = chunkDirectory
        self.chunkSeconds = chunkSeconds
        self.micFormat = micFormat
        self.systemFormat = systemFormat
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)

        self.micFramesPerChunk = AVAudioFrameCount(micFormat.sampleRate * chunkSeconds)
        self.systemFramesPerChunk = AVAudioFrameCount(systemFormat.sampleRate * chunkSeconds)
    }

    // MARK: - Public

    func appendMic(_ buffer: AVAudioPCMBuffer) {
        guard !finalized else { return }
        if startedAt == nil { startedAt = Date() }
        if micFile == nil { rotateIfNeeded(forced: true) }

        do {
            try micFile?.write(from: buffer)
            micFramesInChunk += buffer.frameLength
        } catch {
            log("Mic chunk write failed: \(error)", ok: false)
        }
        rotateIfNeeded()
    }

    func appendSystem(_ buffer: AVAudioPCMBuffer) {
        guard !finalized else { return }
        if startedAt == nil { startedAt = Date() }
        if systemFile == nil { rotateIfNeeded(forced: true) }

        do {
            try systemFile?.write(from: buffer)
            systemFramesInChunk += buffer.frameLength
        } catch {
            log("System chunk write failed: \(error)", ok: false)
        }
        rotateIfNeeded()
    }

    /// Called when both streams are confirmed stopped. Closes any open chunk
    /// (renaming .tmp → final), writes metadata, and writes `done.flag`.
    func finalize() {
        guard !finalized else { return }
        finalized = true
        closeCurrentChunk()
        let flag = chunkDirectory.appendingPathComponent("done.flag")
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? stamp.write(to: flag, atomically: true, encoding: .utf8)
        log("Chunk recording finalized — \(chunkIndex) chunk(s)")
    }

    // MARK: - Rotation

    private func rotateIfNeeded(forced: Bool = false) {
        let micFull = micFramesInChunk >= micFramesPerChunk
        let systemFull = systemFramesInChunk >= systemFramesPerChunk
        guard forced || micFull || systemFull else { return }

        // Close the finished chunk, then advance the index BEFORE opening the
        // next one — otherwise the reopened file is created at the old index
        // while the following close() looks for index+1, so the atomic rename
        // no-ops and live audio is stranded in a `.tmp` past chunk 0000.
        if !forced { closeCurrentChunk(); chunkIndex += 1 }

        let i = chunkIndex
        let micURL = chunkDirectory.appendingPathComponent(String(format: "chunk-%04d-mic.wav", i))
        let sysURL = chunkDirectory.appendingPathComponent(String(format: "chunk-%04d-sys.wav", i))

        do {
            // Use the source format directly. AVAudioFile writes a valid WAV
            // header for 32-bit float. WhisperKit reads this fine.
            micFile = try AVAudioFile(forWriting: micURL.appendingPathExtension("tmp"),
                                       settings: micFormat.settings,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            systemFile = try AVAudioFile(forWriting: sysURL.appendingPathExtension("tmp"),
                                         settings: systemFormat.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
            micFramesInChunk = 0
            systemFramesInChunk = 0
        } catch {
            log("Failed to open chunk \(i): \(error)", ok: false)
            return
        }
    }

    private func closeCurrentChunk() {
        let i = chunkIndex
        let micURL = chunkDirectory.appendingPathComponent(String(format: "chunk-%04d-mic.wav", i))
        let sysURL = chunkDirectory.appendingPathComponent(String(format: "chunk-%04d-sys.wav", i))
        let metaURL = chunkDirectory.appendingPathComponent(String(format: "chunk-%04d.metadata.json", i))

        // Trigger file close by releasing the AVAudioFile reference
        micFile = nil
        systemFile = nil

        // Rename .tmp → final atomically
        renameAtomic(micURL.appendingPathExtension("tmp"), to: micURL)
        renameAtomic(sysURL.appendingPathExtension("tmp"), to: sysURL)

        // Write metadata
        let meta: [String: Any] = [
            "index": i,
            "micFrames": micFramesInChunk,
            "systemFrames": systemFramesInChunk,
            "micSampleRate": micFormat.sampleRate,
            "systemSampleRate": systemFormat.sampleRate,
            "closedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func renameAtomic(_ source: URL, to destination: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try? fm.moveItem(at: source, to: destination)
    }

    private nonisolated func log(_ msg: String, ok: Bool = true) {
        Task { @MainActor in
            DebugLog.shared.log(icon: "🧱", label: "ChunkWriter", value: msg, ok: ok)
        }
    }
}
