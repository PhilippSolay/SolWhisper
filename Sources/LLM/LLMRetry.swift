import Foundation

/// Exponential-backoff retry for LLM and cloud-diarization calls. Covers
/// the failure modes that are *not* the caller's fault:
///   • upstream 5xx (502/503/504 from CDN/proxy)
///   • 408 / 429 (request timeout / rate limit at the provider)
///   • NSURLError transport hiccups (timeout, connection lost, DNS, etc.)
///
/// 4xx (other than 408/429) are surfaced immediately — those are bad
/// requests, missing keys, model-not-found, etc., and retrying is just
/// noise. Decoding errors aren't retried either; if the provider gave us
/// a malformed response, the next call probably will too.
enum LLMRetry {

    /// 3 attempts total (initial + 2 retries). Backoff at 1s, 2s — caps
    /// added latency on a stubborn outage at ~3s of sleep before the
    /// final failure surfaces to the UI.
    static let maxAttempts = 3
    static let baseDelaySec: TimeInterval = 1.0

    /// Whether this error is worth retrying. Public so streaming wrappers
    /// in concrete clients can reuse the same classification.
    static func isRetryable(_ error: Error) -> Bool {
        if let llmError = error as? LLMError {
            if case .http(let status, _) = llmError {
                return (500...599).contains(status) || status == 408 || status == 429
            }
            return false
        }
        if let diarError = error as? DiarizationError {
            if case .http(let status, _) = diarError {
                return (500...599).contains(status) || status == 408 || status == 429
            }
            return false
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Run a one-shot async operation with retry. Use for `complete` and
    /// for the upload phase of cloud diarizers.
    static func run<T: Sendable>(_ label: String,
                                  _ operation: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                let isLast = attempt == maxAttempts - 1
                guard isRetryable(error), !isLast else { throw error }
                let delay = baseDelaySec * pow(2.0, Double(attempt))
                await DebugLog.shared.log(
                    icon: "🔁",
                    label: "Retry \(label)",
                    value: "attempt \(attempt + 1)/\(maxAttempts) after \(error.localizedDescription.prefix(80)) — waiting \(Int(delay))s"
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? LLMError.http(status: 0, body: "retry exhausted")
    }

    /// Run a streaming operation with retry. Retries only fire if the
    /// stream errors *before* yielding any chunks — once we've started
    /// delivering text we can't redo the request without duplicating
    /// output, so partial-stream failures are surfaced immediately.
    static func runStream(_ label: String,
                           _ make: @escaping @Sendable () -> AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for attempt in 0..<maxAttempts {
                    let stream = make()
                    var yieldedAny = false
                    do {
                        for try await chunk in stream {
                            yieldedAny = true
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    } catch {
                        let isLast = attempt == maxAttempts - 1
                        if yieldedAny || !isRetryable(error) || isLast {
                            continuation.finish(throwing: error)
                            return
                        }
                        let delay = baseDelaySec * pow(2.0, Double(attempt))
                        await DebugLog.shared.log(
                            icon: "🔁",
                            label: "Retry \(label) (stream)",
                            value: "attempt \(attempt + 1)/\(maxAttempts) after \(error.localizedDescription.prefix(80)) — waiting \(Int(delay))s"
                        )
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
