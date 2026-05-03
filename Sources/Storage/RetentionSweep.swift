import Foundation

/// Deletes meeting recordings + dictation history older than the user's
/// retention policy. Runs once at app launch.
enum RetentionPolicy: String, CaseIterable {
    case forever = "forever"
    case days7   = "7d"
    case days30  = "30d"
    case days90  = "90d"
    case days365 = "365d"

    var label: String {
        switch self {
        case .forever: return "Forever"
        case .days7:   return "7 days"
        case .days30:  return "30 days"
        case .days90:  return "90 days"
        case .days365: return "1 year"
        }
    }

    /// Maximum age in seconds. `nil` = retention disabled.
    var maxAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .days7:   return   7 * 86_400
        case .days30:  return  30 * 86_400
        case .days90:  return  90 * 86_400
        case .days365: return 365 * 86_400
        }
    }
}

@MainActor
enum RetentionSweep {

    /// Runs the sweep if the policy is non-`forever`. Throttled to once per
    /// hour so launches in quick succession don't hammer the disk.
    static func run(meetingStore: MeetingStore) {
        let raw = UserDefaults.standard.string(forKey: "retentionPolicy") ?? "forever"
        let policy = RetentionPolicy(rawValue: raw) ?? .forever
        guard let maxAge = policy.maxAge else { return }

        let last = UserDefaults.standard.double(forKey: "retentionLastSweepAt")
        let now = Date().timeIntervalSince1970
        if last > 0 && (now - last) < 3_600 { return }
        UserDefaults.standard.set(now, forKey: "retentionLastSweepAt")

        let cutoff = Date().addingTimeInterval(-maxAge)
        sweepMeetings(meetingStore, olderThan: cutoff)
        sweepDictationHistory(olderThan: cutoff)

        // Bonus: keep the error log dir from growing unbounded.
        ErrorLogger.shared.sweepOldLogs()

        DebugLog.shared.log(icon: "🧹", label: "Retention sweep",
                            value: "policy=\(policy.rawValue)")
    }

    private static func sweepMeetings(_ store: MeetingStore, olderThan cutoff: Date) {
        let stale = store.meetings.filter { $0.createdAt < cutoff }
        for m in stale {
            do {
                try store.delete(m)
            } catch {
                DebugLog.shared.log(icon: "🧹", label: "Retention: meeting delete failed",
                                    value: "\(error)", ok: false)
            }
        }
        if !stale.isEmpty {
            DebugLog.shared.log(icon: "🧹", label: "Retention: meetings",
                                value: "deleted \(stale.count)")
        }
    }

    private static func sweepDictationHistory(olderThan cutoff: Date) {
        let store = DictationHistoryStore.shared
        let stale = store.entries.filter { $0.createdAt < cutoff }
        for e in stale {
            store.delete(e)
        }
        if !stale.isEmpty {
            DebugLog.shared.log(icon: "🧹", label: "Retention: dictation",
                                value: "deleted \(stale.count)")
        }
    }
}
