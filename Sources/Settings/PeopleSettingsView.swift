import SwiftUI

/// Settings → People — manages voice profiles + the calendar attendee
/// link. Voice fingerprinting itself (embedding extraction + match) is
/// scaffolded here for v0.6; the data model + name autocomplete already
/// work today.
struct PeopleSettingsView: View {

    @StateObject private var store = VoiceProfileStore.shared
    @StateObject private var calendar = CalendarIntegration.shared
    @State private var newName: String = ""
    @State private var deleteConfirmTarget: VoiceProfile?

    /// The user's own display name. Speaker badges matching this name (and
    /// the [Me] mic channel) render in white in transcripts so the user
    /// can spot themselves at a glance.
    @AppStorage("userDisplayName") private var userDisplayName: String = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Your name (e.g. Philipp)", text: $userDisplayName)
                }
                .padding(.vertical, 2)
            } header: {
                Text("You")
            } footer: {
                Text("Speakers in any transcript matching this name (case-insensitive) — plus the [Me] mic channel — render in white so you can spot your own lines at a glance.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: calendarStatusIcon)
                        .foregroundColor(calendarStatusColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calendarStatusLabel)
                            .font(.system(size: 13, weight: .medium))
                        Text("When granted, attendees from calendar events near each meeting's start time become rename suggestions and feed the AI model speaker matcher.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if !calendarHasAccess {
                        Button("Grant access") {
                            Task { _ = await calendar.requestAccessIfNeeded() }
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: { Text("Calendar") }

            Section {
                if store.profiles.isEmpty {
                    Text("No voice profiles yet. To capture a real voiceprint, open a meeting in Transcripts → click any speaker badge → \"Save as profile\". Or just add a name below as an autocomplete entry.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(store.profiles) { profile in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.system(size: 13, weight: .medium))
                                HStack(spacing: 6) {
                                    if profile.hasEmbedding {
                                        Label("voiceprint stored — auto-matches in future meetings", systemImage: "waveform.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.green)
                                    } else {
                                        Label("name only — capture a voiceprint by clicking a speaker badge in a transcript", systemImage: "person.crop.circle.badge.questionmark")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    if let mid = profile.sourceMeetingID {
                                        Text("· source: meeting \(mid.uuidString.prefix(8))")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                deleteConfirmTarget = profile
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete voice profile")
                        }
                        .padding(.vertical, 2)
                    }
                }
                HStack {
                    TextField("Add name…", text: $newName)
                        .onSubmit { addProfile() }
                    Button("Add") { addProfile() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Voice profiles")
            } footer: {
                Text("Profiles serve two roles. **(1) Name autocomplete** when renaming speakers — works for any profile. **(2) Auto-matching** on diarized meetings — requires a stored voiceprint. To get a voiceprint, click a speaker badge in any transcript, type the name, and tap \"Save as profile\". The embedding extraction runs locally via FluidAudio (macOS 14+) and persists alongside the name.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("People")
        .alert("Delete this profile?",
               isPresented: Binding(
                get: { deleteConfirmTarget != nil },
                set: { if !$0 { deleteConfirmTarget = nil } }
               )) {
            Button("Cancel", role: .cancel) { deleteConfirmTarget = nil }
            Button("Delete", role: .destructive) {
                if let p = deleteConfirmTarget {
                    store.delete(p)
                }
                deleteConfirmTarget = nil
            }
        } message: {
            Text("\"\(deleteConfirmTarget?.name ?? "")\" will be removed. The voiceprint (if stored) is deleted with it.")
        }
    }

    private func addProfile() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.add(VoiceProfile(name: name))
        newName = ""
    }

    // MARK: - Calendar status

    private var calendarHasAccess: Bool {
        if #available(macOS 14.0, *) {
            return calendar.authStatus == .fullAccess
        }
        return calendar.authStatus == .authorized
    }

    private var calendarIsDenied: Bool {
        calendar.authStatus == .denied || calendar.authStatus == .restricted
    }

    private var calendarStatusIcon: String {
        if calendarHasAccess { return "checkmark.seal.fill" }
        if calendarIsDenied  { return "xmark.seal.fill" }
        return "questionmark.seal"
    }

    private var calendarStatusColor: Color {
        if calendarHasAccess { return .green }
        if calendarIsDenied  { return .red }
        return .secondary
    }

    private var calendarStatusLabel: String {
        if calendarHasAccess { return "Calendar access granted" }
        switch calendar.authStatus {
        case .denied:      return "Calendar access denied — fix in System Settings → Privacy & Security → Calendars"
        case .restricted:  return "Calendar access restricted by system policy"
        default:           return "Calendar access not yet granted"
        }
    }
}
