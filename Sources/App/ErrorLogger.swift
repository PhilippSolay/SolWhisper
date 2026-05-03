import Foundation

/// Per-day error log file written under `~/Library/Logs/SolWhisper/`.
/// Gated by the `errorLoggingEnabled` UserDefault. Designed as a thin
/// drop-in for ad-hoc print/os_log error sites — call `.log(_:error:)`.
@MainActor
final class ErrorLogger {

    static let shared = ErrorLogger()

    private static let dirName = "SolWhisper"
    private static let maxRetainedDays = 14

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    var isEnabled: Bool {
        // Default true if unset.
        if UserDefaults.standard.object(forKey: "errorLoggingEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "errorLoggingEnabled")
    }

    /// Resolves and creates the log directory if needed.
    var logDirectory: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        let dir = logs.appendingPathComponent(Self.dirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var todaysURL: URL {
        logDirectory.appendingPathComponent("errors-\(dayFmt.string(from: Date())).log")
    }

    /// Appends a single entry. No-op when logging is disabled.
    func log(_ message: String, error: Error? = nil, file: StaticString = #file, line: UInt = #line) {
        guard isEnabled else { return }

        let fileName = (String(describing: file) as NSString).lastPathComponent
        var line = "[\(fmt.string(from: Date()))] \(fileName):\(line)  \(message)"
        if let error {
            line += "  — \(error.localizedDescription)"
        }
        line += "\n"

        let url = todaysURL
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Trims log files older than `maxRetainedDays`. Cheap; safe to run on
    /// every launch.
    func sweepOldLogs() {
        let cutoff = Calendar.current.date(byAdding: .day,
                                           value: -Self.maxRetainedDays,
                                           to: Date()) ?? Date.distantPast
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries where url.pathExtension == "log" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            if mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
