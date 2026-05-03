import SwiftUI

struct TranscriptsRootView: View {

    @ObservedObject var store: MeetingStore
    let onUpload: () -> Void

    enum Tab: String, Hashable, CaseIterable, Identifiable {
        case meetings = "Meetings"
        case history  = "History"
        var id: String { rawValue }
    }

    @State private var selection: UUID?
    @State private var tab: Tab = .meetings
    @State private var searchVisible: Bool = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Spacer()

                    Button {
                        searchVisible.toggle()
                    } label: {
                        Image(systemName: searchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(searchVisible ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(searchVisible ? "Hide search" : "Search")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

                switch tab {
                case .meetings:
                    MeetingListView(store: store,
                                    selection: $selection,
                                    onUpload: onUpload,
                                    searchVisible: $searchVisible)
                case .history:
                    DictationHistoryListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            switch tab {
            case .meetings:
                if let id = selection,
                   let meeting = store.meetings.first(where: { $0.id == id }) {
                    MeetingDetailView(
                        meeting: meeting,
                        store: store,
                        onDeleted: { selection = nil }
                    )
                } else {
                    emptyMeetingsState
                }
            case .history:
                emptyHistoryState
            }
        }
        .toolbar(.hidden)
        .frame(minWidth: 800, minHeight: 520)
    }

    private var emptyMeetingsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Pick a meeting")
                .font(.system(size: 14, weight: .medium))
            Text("Choose a meeting from the sidebar, or upload an audio file.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Upload audio file…") { onUpload() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHistoryState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("Dictation history")
                .font(.system(size: 14, weight: .medium))
            Text("Past mode-A dictation sessions will appear here. You'll be able to re-paste, re-polish, or copy any earlier transcript.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("Coming in v0.5.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sidebar list for the History tab — backed by `DictationHistoryStore`.
struct DictationHistoryListView: View {
    @StateObject private var store = DictationHistoryStore.shared
    @State private var copied: UUID?

    var body: some View {
        if store.entries.isEmpty {
            emptyState
        } else {
            List {
                ForEach(store.entries) { entry in
                    HistoryRow(entry: entry,
                               isCopied: copied == entry.id,
                               onCopy: { copyToClipboard(entry) },
                               onDelete: { store.delete(entry) })
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No history yet")
                .font(.system(size: 12, weight: .medium))
            Text("Past dictation sessions will appear here.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyToClipboard(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.polishedText, forType: .string)
        copied = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copied == entry.id { copied = nil }
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatTime(entry.createdAt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(entry.wordCount) words")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(entry.polishedText)
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let app = entry.targetAppName {
                    Text(app)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text("·")
                    .foregroundColor(.secondary)
                Text(entry.backend)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(isCopied ? "Copied!" : "Copy to clipboard")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
        }
        .padding(.vertical, 6)
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
