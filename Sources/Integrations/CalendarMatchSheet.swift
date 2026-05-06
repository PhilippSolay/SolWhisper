import EventKit
import SwiftUI

/// Confirmation sheet shown when the user clicks "Link calendar event".
///
/// Lists every event whose time range overlaps the meeting (±15 min). If
/// only one event was found we still surface this sheet so the user
/// confirms the title + attendee list before we write them to the
/// meeting; if multiple events match, the user picks one.
struct CalendarMatchSheet: View {

    /// Pre-filtered candidates from `CalendarIntegration.eventsAroundMeeting`.
    let candidates: [EKEvent]
    /// Best guess pre-selected by the runner; user can override.
    let bestMatch: EKEvent?
    let attendeeNames: (EKEvent) -> [String]
    /// Returns (title, attendees, eventID) when user confirms.
    let onConfirm: (_ title: String, _ attendees: [String], _ eventID: String) -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.accentColor)
                Text("Link a calendar event")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(candidates.count) event\(candidates.count == 1 ? "" : "s") in time window")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            Divider()

            if candidates.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates, id: \.eventIdentifier) { event in
                            eventRow(event)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip — don't link") {
                    onSkip()
                }
                .controlSize(.regular)
                Button("Link selected") {
                    if let id = selectedID,
                       let event = candidates.first(where: { $0.eventIdentifier == id }) {
                        let names = attendeeNames(event)
                        onConfirm(event.title ?? "Untitled", names, event.eventIdentifier ?? "")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 460)
        .onAppear {
            selectedID = bestMatch?.eventIdentifier ?? candidates.first?.eventIdentifier
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No calendar events found")
                .font(.system(size: 13, weight: .medium))
            Text("No events were scheduled around the time of this recording. You can grant Calendar access in Settings → People if you haven't, or skip linking.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
    }

    @ViewBuilder
    private func eventRow(_ event: EKEvent) -> some View {
        let isSelected = (event.eventIdentifier == selectedID)
        let names = attendeeNames(event)
        Button {
            selectedID = event.eventIdentifier
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title ?? "Untitled event")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(timeLabel(event))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        if let cal = event.calendar?.title {
                            Text("·").foregroundColor(.secondary)
                            Text(cal).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }

                    if names.isEmpty {
                        Text("No attendees on this event")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Attendees (\(names.count))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                            FlowText(items: names)
                                .font(.system(size: 11))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isSelected
                        ? Color.accentColor.opacity(0.08)
                        : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func timeLabel(_ event: EKEvent) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let s = f.string(from: event.startDate)
        let e = DateFormatter()
        e.dateStyle = .none
        e.timeStyle = .short
        return "\(s) – \(e.string(from: event.endDate))"
    }
}

/// Comma-separated name list that wraps. Cheaper than implementing a
/// real flow layout for this small case.
private struct FlowText: View {
    let items: [String]
    var body: some View {
        Text(items.joined(separator: ", "))
            .font(.system(size: 11))
            .foregroundColor(.primary.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
    }
}
