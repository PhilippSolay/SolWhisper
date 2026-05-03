import Foundation
import AVFoundation

/// Thin wrapper around `WhisperKitClient.fileTranscribe` that:
///   1. Validates the audio file is decodable by AVFoundation up-front.
///   2. Forwards progress to the caller via `@MainActor` callbacks.
///   3. Returns segments in our in-app `TranscriptDocument` shape.
///
/// Stays decoupled from `MeetingStore` so it's reusable from anywhere
/// (live-recording transcribe, future re-process flows, integration tests).
@MainActor
enum FileTranscriber {

    enum Error: Swift.Error, LocalizedError {
        case unreadableAudio(URL)
        case underlying(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .unreadableAudio(let url):
                return "Couldn't read audio at \(url.lastPathComponent). Is it a supported format?"
            case .underlying(let err):
                return err.localizedDescription
            }
        }
    }

    /// Reasonable defaults; matches the file types we accept in the open panel.
    static let acceptedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "mp4", "flac", "ogg", "aac", "aiff", "aif", "caf"
    ]

    /// Validates the file with `AVAudioFile`. Cheap (just opens the header)
    /// and rejects unsupported formats before paying for a model load.
    static func validate(_ audioURL: URL) throws {
        do {
            _ = try AVAudioFile(forReading: audioURL)
        } catch {
            throw Error.unreadableAudio(audioURL)
        }
    }

    /// Returns the audio duration in seconds, or 0 if it can't be determined.
    static func durationSeconds(_ audioURL: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return 0 }
        let frames = Double(file.length)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return frames / rate
    }

    /// Runs the WhisperKit pipeline on `audioURL` and returns a fully-formed
    /// `TranscriptDocument` plus the joined plain text.
    ///
    /// Progress is reported on @MainActor; values are 0.0–1.0.
    /// Cancellation propagates via `Task.cancel()`.
    static func transcribe(
        audioURL: URL,
        meetingID: UUID,
        model: String,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> (document: TranscriptDocument, plainText: String) {
        try validate(audioURL)

        let segments: [TranscriptSegment]
        do {
            segments = try await WhisperKitClient.fileTranscribe(
                audioPath: audioURL,
                model: model,
                progress: { fraction in
                    Task { @MainActor in progress(fraction) }
                }
            )
        } catch {
            throw Error.underlying(error)
        }

        let document = TranscriptDocument(meetingID: meetingID, segments: segments)
        let joined = segments.map { $0.text }.joined(separator: " ")
                                              .trimmingCharacters(in: .whitespacesAndNewlines)
        return (document, joined)
    }

    /// Renders a transcript document as a human-readable Markdown string.
    /// Used for the per-meeting `transcript.md` companion file.
    static func renderMarkdown(_ document: TranscriptDocument, title: String) -> String {
        var out = "# \(title)\n\n"
        for segment in document.segments {
            let stamp = formatTimestamp(segment.start)
            out += "**\(stamp)** \(segment.text)\n\n"
        }
        return out
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
