import Foundation

/// Buckets meetings into the four sidebar sections from the spec
/// (Today / Yesterday / This Week / Earlier).
///
/// Pure value-type so it's testable without instantiating a SwiftUI view.
enum MeetingTimeBucket: Int, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case earlier

    var title: String {
        switch self {
        case .today:     return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek:  return "This Week"
        case .earlier:   return "Earlier"
        }
    }

    /// Computes the bucket for a meeting's `createdAt` relative to `reference`
    /// (default: now). Uses the user's calendar for day boundaries.
    static func bucket(for date: Date, reference: Date = Date(),
                       calendar: Calendar = .current) -> MeetingTimeBucket {
        if calendar.isDate(date, inSameDayAs: reference) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        if calendar.isDate(date, equalTo: reference, toGranularity: .weekOfYear) {
            return .thisWeek
        }
        return .earlier
    }

    /// Returns `meetings` partitioned and ordered for sidebar display.
    /// Within each bucket, meetings are newest-first by `createdAt`.
    static func grouped(_ meetings: [Meeting], reference: Date = Date(),
                        calendar: Calendar = .current) -> [(bucket: MeetingTimeBucket, meetings: [Meeting])] {
        var result: [MeetingTimeBucket: [Meeting]] = [:]
        for m in meetings {
            let bucket = MeetingTimeBucket.bucket(for: m.createdAt,
                                                   reference: reference,
                                                   calendar: calendar)
            result[bucket, default: []].append(m)
        }
        return MeetingTimeBucket.allCases.compactMap { bucket in
            guard let list = result[bucket], !list.isEmpty else { return nil }
            return (bucket: bucket, meetings: list.sorted(by: { $0.createdAt > $1.createdAt }))
        }
    }
}
