import SwiftUI
import AppKit

/// "Dictation input" section of the Languages pane: pick the STT input
/// language and see per-language readiness for the active dictation engine.
/// The tray Input Language menu offers the ready subset of this list; its
/// "Add Language…" item lands here.
struct DictationLanguagesSection: View {

    @AppStorage(DictationLanguage.defaultsKey) private var selectedID = DictationLanguage.fallback.id
    @AppStorage("transcriptionBackend") private var backend = "apple"

    @State private var status: [String: LanguageReadiness] = [:]

    var body: some View {
        Section {
            Picker("Input language", selection: $selectedID) {
                ForEach(DictationLanguage.curated) { lang in
                    Text(lang.label).tag(lang.id)
                }
            }
            ForEach(DictationLanguage.curated) { lang in
                row(for: lang)
            }
        } header: {
            Text("Dictation input")
        } footer: {
            Text(footer).font(.caption).foregroundColor(.secondary)
        }
        .onAppear(perform: refresh)
        .onChange(of: backend) { _, _ in refresh() }
        .onChange(of: selectedID) { _, _ in refresh() }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for lang: DictationLanguage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.label)
                Text(statusText(status[lang.id]))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            action(for: lang)
        }
    }

    @ViewBuilder
    private func action(for lang: DictationLanguage) -> some View {
        switch status[lang.id] {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .accessibilityLabel("Ready")
        case .needsDownload:
            if backend == "whisperkit" {
                Button("Get multilingual model") { SettingsDeepLink.open(.models) }
                    .buttonStyle(.bordered)
            } else {
                Button("Open System Settings") { openDictationSystemSettings() }
                    .buttonStyle(.bordered)
            }
        case .unsupported:
            Text("Not supported").font(.caption).foregroundColor(.secondary)
        case .llmFallback, .modelDependent, .none:
            ProgressView().controlSize(.small)
        }
    }

    private func statusText(_ readiness: LanguageReadiness?) -> String {
        switch readiness {
        case .ready:
            return "Ready"
        case .needsDownload:
            return backend == "whisperkit"
                ? "Needs a multilingual WhisperKit model"
                : "macOS dictation pack not installed"
        case .unsupported:
            return "Not supported by Apple Speech on this Mac"
        case .llmFallback, .modelDependent, .none:
            return "Checking…"
        }
    }

    private var footer: String {
        switch backend {
        case "whisperkit":
            return "WhisperKit dictates every listed language once a multilingual model (one without “.en” in its name) is downloaded and selected in Settings → Models."
        case "deepgram":
            return "Deepgram transcribes all listed languages in the cloud — nothing to download."
        default:
            return "Apple Speech runs on-device using macOS dictation packs. Add languages in System Settings → Keyboard → Dictation, then come back — no restart needed."
        }
    }

    // MARK: - Actions

    /// macOS offers no API to install dictation packs — deep-link the pane
    /// where the user can. Try-each pattern mirrors the translate section.
    private func openDictationSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    private func refresh() {
        status = DictationLanguage.curated.reduce(into: [:]) { acc, lang in
            acc[lang.id] = DictationLanguageAvailability.readiness(for: lang, backend: backend)
        }
    }
}
