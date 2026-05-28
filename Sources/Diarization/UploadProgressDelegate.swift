import Foundation

/// `URLSessionTaskDelegate` that forwards upload-progress callbacks to a
/// closure. Used by the cloud diarizers so the UI progress bar reflects
/// real bytes-sent during a multi-minute audio upload instead of parking
/// at a single pre-upload tick.
///
/// URLSession invokes `didSendBodyData` on its own delegate queue; the
/// caller is responsible for hopping back to MainActor before touching
/// SwiftUI state.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// Called every time URLSession reports more bytes flushed. Argument
    /// is the cumulative fraction in 0…1. Set on the main thread before
    /// the upload starts; URLSession will invoke it from its delegate queue.
    var onProgress: (@Sendable (Double) -> Void)?

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress?(min(max(fraction, 0), 1))
    }
}
