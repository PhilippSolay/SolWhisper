import SwiftUI

/// Sidebar — filter field, upload button, grouped list of meetings.
/// Sprint 3 keeps this read-only: no rename, delete, or context menus yet.
struct MeetingListView: View {

    @ObservedObject var store: MeetingStore
    @Binding var selection: UUID?
    let onUpload: () -> Void
    @Binding var searchVisible: Bool

    @State private var filter: String = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Meeting] {
        if filter.isEmpty { return store.meetings }
        let needle = filter.lowercased()
        return store.meetings.filter { $0.title.lowercased().contains(needle) }
    }

    private var grouped: [(bucket: MeetingTimeBucket, meetings: [Meeting])] {
        MeetingTimeBucket.grouped(filtered)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar shows/hides via the magnifier toggle in the parent
            // tab bar. Hidden by default to keep the meeting browse view clean.
            if searchVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("Filter meetings…", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .onSubmit { searchFocused = false }
                    if !filter.isEmpty {
                        Button {
                            filter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .onAppear { searchFocused = true }

                Divider()
            }

            if store.meetings.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatchState
            } else {
                List(selection: $selection) {
                    ForEach(grouped, id: \.bucket) { group in
                        Section(header: Text(group.bucket.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)) {
                            ForEach(group.meetings) { meeting in
                                MeetingRow(meeting: meeting).tag(meeting.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            VStack(spacing: 8) {
                uploadButton
                openFolderButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        // Liquid Glass primary button on macOS 26+; falls back to the
        // standard prominent style on older systems so the action is
        // still clearly the primary affordance.
        if #available(macOS 26.0, *) {
            Button(action: onUpload) {
                Label("Upload audio file", systemImage: "arrow.up.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        } else {
            Button(action: onUpload) {
                Label("Upload audio file", systemImage: "arrow.up.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var openFolderButton: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([store.rootDirectory])
        } label: {
            Label("Open folder", systemImage: "folder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No meetings yet")
                .font(.system(size: 12, weight: .medium))
            Text("Record a meeting from the menu bar (⌃⌥⌘M), or upload an audio file.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
    }

    private var noMatchState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No meetings match \"\(filter)\"")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
    }

}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(formatDate(meeting.createdAt))
                if meeting.durationSeconds > 0 {
                    Text("·")
                    Text(formatDuration(meeting.durationSeconds))
                }
                if meeting.source == .import {
                    Text("·")
                    Text("imported")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
