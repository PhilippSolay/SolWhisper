import EventKit
import Foundation

/// Reads macOS Calendar events near a meeting's start time so we can
/// pre-fill participants and offer real names when renaming speakers.
///
/// Permission is requested lazily — the first call to any read method
/// triggers the system prompt. Once granted, results are cached
/// per-meeting via the calling code.
@MainActor
final class CalendarIntegration: ObservableObject {

    static let shared = CalendarIntegration()

    /// Match window: how far before/after the meeting's `createdAt` we
    /// search for an overlapping calendar event. Calendar entries
    /// often start a couple of minutes before the actual recording.
    private let matchWindowMinutes: TimeInterval = 15

    private let store = EKEventStore()

    @Published var authStatus: EKAuthorizationStatus

    init() {
        self.authStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Asks the user for Calendar access if we don't already have it.
    /// macOS 14+ uses `requestFullAccessToEvents`; older versions use
    /// the deprecated `requestAccess(to:completion:)`.
    func requestAccessIfNeeded() async -> Bool {
        let current = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch current {
            case .fullAccess: return true
            case .denied, .restricted: return false
            default: break
            }
            do {
                let granted = try await store.requestFullAccessToEvents()
                authStatus = EKEventStore.authorizationStatus(for: .event)
                return granted
            } catch {
                DebugLog.shared.log(icon: "📅", label: "Calendar access request failed",
                                    value: "\(error)", ok: false)
                return false
            }
        } else {
            switch current {
            case .authorized: return true
            case .denied, .restricted: return false
            default: break
            }
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { granted, _ in
                    Task { @MainActor in
                        self.authStatus = EKEventStore.authorizationStatus(for: .event)
                    }
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Returns calendar events whose time range intersects the given
    /// meeting's time window (createdAt ± matchWindowMinutes). Empty if
    /// access is denied or no overlap is found.
    func eventsAroundMeeting(_ meeting: Meeting) -> [EKEvent] {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (EKEventStore.authorizationStatus(for: .event) == .fullAccess)
        } else {
            granted = (EKEventStore.authorizationStatus(for: .event) == .authorized)
        }
        guard granted else { return [] }

        let pad = matchWindowMinutes * 60
        let predicate = store.predicateForEvents(
            withStart: meeting.createdAt.addingTimeInterval(-pad),
            end: meeting.createdAt.addingTimeInterval(meeting.durationSeconds + pad),
            calendars: nil
        )
        return store.events(matching: predicate)
    }

    /// Picks the single calendar event that best overlaps the meeting's
    /// recorded window. Heuristic: most overlap with the meeting span.
    func bestMatch(for meeting: Meeting) -> EKEvent? {
        let candidates = eventsAroundMeeting(meeting)
        guard !candidates.isEmpty else { return nil }
        let mStart = meeting.createdAt
        let mEnd   = meeting.createdAt.addingTimeInterval(max(meeting.durationSeconds, 1))
        return candidates.max(by: { a, b in
            overlap(a, mStart: mStart, mEnd: mEnd) < overlap(b, mStart: mStart, mEnd: mEnd)
        })
    }

    /// Pulls human-readable names from an event: organizer + attendees.
    /// Filters out the user's own calendar identity (no point auto-suggesting "Me").
    func attendeeNames(for event: EKEvent) -> [String] {
        var out = Set<String>()
        if let org = event.organizer?.name, !org.isEmpty {
            out.insert(org)
        }
        for attendee in event.attendees ?? [] {
            // Skip "current user" entries — EKParticipant exposes this via
            // isCurrentUser on macOS 14+.
            if #available(macOS 14.0, *), attendee.isCurrentUser { continue }
            if let name = attendee.name, !name.isEmpty {
                out.insert(name)
            } else if !attendee.url.absoluteString.isEmpty {
                // Fall back to the email local-part if no display name.
                let email = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                if let local = email.split(separator: "@").first {
                    out.insert(String(local))
                }
            }
        }
        return Array(out).sorted()
    }

    private func overlap(_ event: EKEvent, mStart: Date, mEnd: Date) -> TimeInterval {
        let s = max(event.startDate, mStart)
        let e = min(event.endDate, mEnd)
        return max(0, e.timeIntervalSince(s))
    }
}
