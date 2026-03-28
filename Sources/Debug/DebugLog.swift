import Foundation
import Combine

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id        = UUID()
    let timestamp = Date()
    let icon:    String
    let label:   String
    let value:   String?
    let ms:      Int?       // duration in ms
    let tokens:  TokenInfo?
    let ok:      Bool       // success / failure tint

    struct TokenInfo {
        let prompt: Int
        let completion: Int
        var total: Int { prompt + completion }
    }
}

// MARK: - DebugLog (singleton)

@MainActor
final class DebugLog: ObservableObject {

    static let shared = DebugLog()
    private init() {}

    @Published private(set) var entries: [LogEntry] = []
    private var enabled: Bool { UserDefaults.standard.bool(forKey: "debugMode") }

    // MARK: Public logging API

    func log(icon: String, label: String, value: String? = nil,
             ms: Int? = nil, tokens: LogEntry.TokenInfo? = nil, ok: Bool = true) {
        guard enabled else { return }
        let e = LogEntry(icon: icon, label: label, value: value, ms: ms, tokens: tokens, ok: ok)
        entries.insert(e, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }

        // Mirror to Xcode console
        var line = "[\(icon)] \(label)"
        if let v = value  { line += " — \(v)" }
        if let m = ms     { line += " (\(m)ms)" }
        if let t = tokens { line += " ↑\(t.prompt)tok ↓\(t.completion)tok" }
        print(line)
    }

    func clear() { entries.removeAll() }
}

// MARK: - Convenience stopwatch

struct Stopwatch {
    private let start = Date()
    var elapsed: Int { Int(Date().timeIntervalSince(start) * 1000) }
}
