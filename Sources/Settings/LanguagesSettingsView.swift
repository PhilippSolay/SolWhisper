import SwiftUI
import AppKit
#if canImport(Translation)
import Translation
#endif

/// Manages the on-device Apple translation language packs used by the Translate
/// and Voice Translate features. Each curated language shows its status and a
/// Download (or Remove) action.
///
/// macOS exposes an API to *download* a pack (by preparing a translation for the
/// pair), but NOT to delete one — removal is only available in System Settings,
/// so the Remove button deep-links there.
struct LanguagesSettingsView: View {

    /// Per-language pack status. `.ready` = installed, `.needsDownload` =
    /// supported but not downloaded, `.unsupported` = not offered on this Mac.
    @State private var status: [String: LanguageReadiness] = [:]
    @State private var busyCode: String?
    @State private var loaded = false

    #if canImport(Translation)
    @State private var downloadPair: LanguagePair?
    #endif

    private var supportsAppleTranslation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var body: some View {
        Form {
            if supportsAppleTranslation {
                Section {
                    ForEach(TranslationLanguage.curated) { lang in
                        row(for: lang)
                    }
                } header: {
                    Text("On-device translation languages")
                } footer: {
                    Text("Apple's on-device translator downloads a pack per language (~50 MB each). Packs work offline and are shared by Translate and Voice Translate. Removal is handled by macOS — the Remove button opens System Settings.")
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Section {
                    Text("On-device translation needs macOS 15 or later. On this version, use the AI model engine instead (Settings → Voice Translate).")
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Languages")
        .task {
            if !loaded { await refreshAll(); loaded = true }
            consumePendingDownload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsSection)) { _ in
            // Deep link fired while this pane is already on screen.
            consumePendingDownload()
        }
        .modifier(PackDownloadModifier(pair: downloadPairBinding, onFinish: { code in
            Task { await refresh(code); busyCode = nil }
        }))
    }

    /// Starts the download a translate flow requested via `SettingsDeepLink`
    /// (pack was missing mid-translation). Runs after `refreshAll` so the
    /// readiness check below is meaningful.
    private func consumePendingDownload() {
        guard let code = SettingsDeepLink.pendingLanguageDownload else { return }
        SettingsDeepLink.pendingLanguageDownload = nil
        guard busyCode == nil, status[code] != .ready, status[code] != .llmFallback else { return }
        startDownload(code)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for lang: TranslationLanguage) -> some View {
        let readiness = status[lang.code]
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.label)
                Text(statusText(readiness)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            actionButton(for: lang, readiness: readiness)
        }
    }

    @ViewBuilder
    private func actionButton(for lang: TranslationLanguage, readiness: LanguageReadiness?) -> some View {
        if busyCode == lang.code {
            ProgressView().controlSize(.small)
        } else {
            switch readiness {
            case .ready:
                Button("Remove", role: .destructive) { openSystemTranslationSettings() }
                    .buttonStyle(.bordered)
            case .needsDownload:
                Button("Download") { startDownload(lang.code) }
                    .buttonStyle(.borderedProminent)
            case .unsupported:
                Text("Not supported").font(.caption).foregroundColor(.secondary)
            case .llmFallback:
                Text("Uses AI model").font(.caption).foregroundColor(.secondary)
            case .modelDependent, .none:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func statusText(_ r: LanguageReadiness?) -> String {
        switch r {
        case .ready:          return "Installed"
        case .needsDownload:  return "Available — not downloaded"
        case .unsupported:    return "Not available on this Mac"
        case .llmFallback:    return "Not supported by Apple — translations use your AI model"
        case .modelDependent, .none: return "Checking…"
        }
    }

    // MARK: - Actions

    private func startDownload(_ code: String) {
        #if canImport(Translation)
        busyCode = code
        downloadPair = LanguagePair(target: code)
        #endif
    }

    /// macOS has no API to delete a downloaded pack — open the system pane where
    /// the user can manage them.
    private func openSystemTranslationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Localization-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.general"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Availability refresh

    private func refreshAll() async {
        var result: [String: LanguageReadiness] = [:]
        for lang in TranslationLanguage.curated {
            result[lang.code] = await TranslationAvailability.readiness(for: lang.code, engine: .apple)
        }
        status = result
    }

    private func refresh(_ code: String) async {
        status[code] = await TranslationAvailability.readiness(for: code, engine: .apple)
    }

    #if canImport(Translation)
    private var downloadPairBinding: Binding<LanguagePair?> {
        Binding(get: { downloadPair }, set: { downloadPair = $0 })
    }
    #endif
}

/// A language pair to prepare/download (source defaults to English — preparing
/// any pair that includes the language downloads its pack).
struct LanguagePair: Equatable {
    var source: String = "en"
    var target: String
}

/// Runs `prepareTranslation()` for a pair to trigger the pack download, then
/// reports completion. Lives on the (visible) settings window so the system
/// download sheet can present. The macOS-15-only `TranslationSession` state is
/// isolated in the gated `…Body` modifier so the type never appears on older OSes.
private struct PackDownloadModifier: ViewModifier {
    @Binding var pair: LanguagePair?
    let onFinish: (String) -> Void

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(PackDownloadModifierBody(pair: $pair, onFinish: onFinish))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct PackDownloadModifierBody: ViewModifier {
    @Binding var pair: LanguagePair?
    let onFinish: (String) -> Void

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                let target = pair?.target
                do { try await session.prepareTranslation() } catch { }
                if let target { onFinish(target) }
                configuration = nil
            }
            .onChange(of: pair) { _, newValue in
                guard let newValue else { configuration = nil; return }
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: newValue.source),
                    target: Locale.Language(identifier: newValue.target)
                )
            }
    }
}
#endif
