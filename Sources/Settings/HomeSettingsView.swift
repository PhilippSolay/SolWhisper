import SwiftUI

/// First-tab Home pane — replaces the old About section as the Settings landing.
/// Shows app branding, lifetime stats placeholders, a "What's new?" feed,
/// and Sparkle update controls. Stats + What's-new feed are scaffolded —
/// real data wiring lands in v0.5.
struct HomeSettingsView: View {

    @AppStorage("SUEnableAutomaticChecks") private var autoUpdateChecks = true
    @AppStorage("errorLoggingEnabled")     private var errorLoggingEnabled = true
    @AppStorage("retentionPolicy")         private var retentionPolicy = "forever"
    @StateObject private var history = DictationHistoryStore.shared
    @StateObject private var launchAtLogin = LaunchAtLogin.shared

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                brandHeader
                statsRow
                whatsNewSection
                updatesSection
                generalSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Home")
    }

    // MARK: - Brand

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Image("SolWhisperLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("SolWhisper").font(.system(size: 18, weight: .semibold))
                Text(appVersion).font(.system(size: 12)).foregroundColor(.secondary)
                Text("Made with love · Studio Solay")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Stats

    private var statsRow: some View {
        let s = HomeStats.compute(from: history.entries)
        return HStack(spacing: 0) {
            StatTile(value: s.wpm, label: "Average WPM",     icon: "speedometer")
            Divider().frame(height: 36)
            StatTile(value: s.wordsThisWeek, label: "Words this week", icon: "text.alignleft")
            Divider().frame(height: 36)
            StatTile(value: s.appsUsedThisWeek, label: "Apps used", icon: "square.stack.3d.up")
            Divider().frame(height: 36)
            StatTile(value: s.savedThisWeek, label: "Saved this week", icon: "clock")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - What's new

    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What's new?")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Link("View all changes",
                     destination: URL(string: "https://github.com/PhilippSolay/SolWhisper/releases")!)
                    .font(.system(size: 11))
            }

            VStack(spacing: 10) {
                let items = WhatsNewItem.bundled
                if items.isEmpty {
                    Text("No release notes shipped with this build.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    ForEach(items) { item in
                        WhatsNewRow(item: item)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Automatically check for updates", isOn: $autoUpdateChecks)
                    Spacer()
                    Button {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdatesNow()
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    // MARK: - General

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("Launch on login", isOn: launchAtLoginBinding)
                        .help("Start SolWhisper automatically when you log in. Toggle here mirrors macOS System Settings → General → Login Items.")
                    Spacer()
                }
                if let err = launchAtLogin.lastError {
                    Text(err)
                        .font(.caption).foregroundColor(.red)
                }

                HStack {
                    Toggle("Error logging", isOn: $errorLoggingEnabled)
                        .help("Writes one log file per day to ~/Library/Logs/SolWhisper/ for support diagnostics. Files older than 14 days are auto-deleted.")
                    Spacer()
                    Button {
                        let url = ErrorLogger.shared.logDirectory
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal logs in Finder", systemImage: "folder")
                    }
                }

                HStack {
                    Text("Keep recordings for")
                        .help("Older meetings and dictation history are deleted automatically on launch when retention is on. Meetings move to Trash; dictation entries are unlinked.")
                    Spacer()
                    Picker("", selection: $retentionPolicy) {
                        ForEach(RetentionPolicy.allCases, id: \.rawValue) { p in
                            Text(p.label).tag(p.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))
            )

            Text("Older meetings and dictation history are deleted on launch when retention is on. 'Forever' disables cleanup.")
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Stat tile

private struct StatTile: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(.secondary)
                Text(value).font(.system(size: 17, weight: .semibold))
            }
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - What's new

struct WhatsNewItem: Identifiable, Decodable {
    let id = UUID()
    let date: String
    let version: String?
    let title: String
    let body: String
    let url: URL?

    private enum CodingKeys: String, CodingKey {
        case date, version, title, body, url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .date)
        // Reformat ISO yyyy-MM-dd into a friendly "MMM d" for the leading column.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let parsed = f.date(from: raw) {
            let out = DateFormatter()
            out.dateFormat = "MMM d"
            self.date = out.string(from: parsed)
        } else {
            self.date = raw
        }
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decode(String.self, forKey: .body)
        if let s = try c.decodeIfPresent(String.self, forKey: .url) {
            self.url = URL(string: s)
        } else {
            self.url = nil
        }
    }

    /// Reads `Resources/whats-new.json` from the bundle.
    /// Falls back to a single "stay tuned" item if the file is missing.
    static let bundled: [WhatsNewItem] = {
        guard let url = Bundle.main.url(forResource: "whats-new",
                                          withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        struct Wrapper: Decodable {
            let version: Int
            let items: [WhatsNewItem]
        }
        let decoded = try? JSONDecoder().decode(Wrapper.self, from: data)
        return decoded?.items ?? []
    }()
}

private struct WhatsNewRow: View {
    let item: WhatsNewItem
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(item.date)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text(item.body)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                if let url = item.url {
                    Link("Try it now", destination: url).font(.system(size: 11))
                }
            }
            Spacer()
        }
    }
}
