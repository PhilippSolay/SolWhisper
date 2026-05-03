import SwiftUI

/// Renamed + restructured from the old `LLMSettingsView`. Routing on top,
/// configured providers below, and a footer of API-key resource links.
/// "+ Add custom model" stub for v0.5.
struct ModelsSettingsView: View {

    @EnvironmentObject private var secrets: SecretsStore

    // STT engines — moved here from STT Short / STT Meetings.
    @AppStorage("transcriptionBackend")     private var shortBackend      = "apple"
    @AppStorage("deepgramApiKey")           private var deepgramApiKey    = ""
    @AppStorage("whisperKitModel")          private var whisperKitModel   = WhisperKitClient.defaultModel
    @AppStorage("meetingsWhisperKitModel")  private var meetingsWKModel   = WhisperKitClient.defaultModel

    @AppStorage("dictationLLMProvider")   private var dictationProvider  = "openrouter"
    @AppStorage("cleanupLLMProvider")     private var cleanupProvider    = "openrouter"
    @AppStorage("summaryLLMProvider")     private var summaryProvider    = "openrouter"

    @StateObject private var modelStore = ModelStore.shared
    @State private var deepgramVisible = false
    @State private var showAddSheet = false

    var body: some View {
        Form {
            // Speech-to-text engines for both modes.
            Section {
                Picker("STT Short", selection: $shortBackend) {
                    Text("Apple Speech  (free · on-device)").tag("apple")
                    Text("WhisperKit  (offline · highest accuracy)").tag("whisperkit")
                    Text("Deepgram nova-3  (cloud)").tag("deepgram")
                }
                switch shortBackend {
                case "apple":
                    Text("On-device · no API key · works offline")
                        .font(.caption).foregroundColor(.secondary)
                case "deepgram":
                    APIKeyField(label: "Deepgram API Key",
                                text: $deepgramApiKey,
                                visible: $deepgramVisible)
                case "whisperkit":
                    WhisperKitModelPicker(title: "WhisperKit model", modelID: $whisperKitModel)
                default:
                    EmptyView()
                }
            } header: { Text("STT Short — dictation engine") }

            Section {
                LabeledContent("STT Meetings") {
                    Text("WhisperKit")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                WhisperKitModelPicker(title: "WhisperKit model", modelID: $meetingsWKModel)
            } header: { Text("STT Meetings — meeting engine") } footer: {
                Text("Apple Speech and Deepgram are mic-only / streaming-only and can't transcribe pre-recorded meeting audio. Meetings always use WhisperKit.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // LLM routing — picks WHICH configured model handles each role.
            // Listed before "Configured models" so the user immediately sees
            // what's actually being used.
            Section {
                routingPicker("Dictation cleanup", selection: $dictationProvider)
                routingPicker("Meeting cleanup",   selection: $cleanupProvider)
                routingPicker("Meeting summary",   selection: $summaryProvider)
            } header: { Text("Routing") } footer: {
                if modelStore.models.isEmpty {
                    Text("No configured models yet — routing falls back to OpenRouter / Ollama defaults. Add a model below to route to it directly.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Each role calls the model you pick. Anthropic, OpenRouter, and Ollama models are called directly with your key; OpenAI / Google / Groq currently route through OpenRouter.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Configured models — unified list. Add via the + button which
            // opens a provider-aware sheet (sets API key + model in one place).
            Section {
                if modelStore.models.isEmpty {
                    Text("No models configured yet.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(modelStore.models) { m in
                        ConfiguredModelRow(
                            model: m,
                            onDelete: { modelStore.delete(m) }
                        )
                    }
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add model…", systemImage: "plus.circle")
                }
            } header: { Text("Configured models") } footer: {
                Text("Cloud models call the provider directly with your own key. Local models run via Ollama. Star a model to mark it as a favorite.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .sheet(isPresented: $showAddSheet) {
            AddModelSheet(onSave: { newModel, apiKey in
                if !apiKey.isEmpty {
                    try? KeychainStore.set(apiKey, forKey: newModel.provider.apiKeyKeychainKey)
                }
                modelStore.add(newModel)
                showAddSheet = false
            }, onCancel: { showAddSheet = false })
        }
    }

    /// Renders a routing picker whose options are: every configured model
    /// (tagged by UUID string), plus the legacy "OpenRouter (default)" and
    /// "Ollama (default)" fallbacks for users who haven't configured a
    /// model yet but still have an OpenRouter / Ollama setup.
    @ViewBuilder
    private func routingPicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            // Configured models, grouped by provider for legibility.
            let grouped = Dictionary(grouping: modelStore.models, by: { $0.provider })
            ForEach(ModelProvider.allCases, id: \.self) { provider in
                if let models = grouped[provider], !models.isEmpty {
                    Section(provider.label) {
                        ForEach(models) { m in
                            Text(m.label).tag(m.id.uuidString)
                        }
                    }
                }
            }
            // Legacy fallbacks — kept so existing installs without a
            // configured model still route correctly.
            Section("Legacy") {
                Text("OpenRouter (default)").tag("openrouter")
                Text("Ollama (default)").tag("ollama")
            }
        }
    }
}

// MARK: - Row

private struct ConfiguredModelRow: View {
    let model: ConfiguredModel
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.provider.symbolIcon)
                .frame(width: 20)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.label)
                    .font(.system(size: 13, weight: .medium))
                Text(model.provider.label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: model.provider.isLocal ? "house" : "cloud")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Remove from list")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Model sheet

private struct AddModelSheet: View {
    let onSave: (ConfiguredModel, String) -> Void
    let onCancel: () -> Void

    @State private var provider: ModelProvider = .anthropic
    @State private var modelID: String = ""
    @State private var displayName: String = ""
    @State private var apiKey: String = ""
    @State private var apiKeyVisible: Bool = false

    var body: some View {
        Form {
            Section {
                Text("Bring your own keys")
                    .font(.system(size: 14, weight: .semibold))
                Text("Configure a model that uses your own API key to connect directly to a provider.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { p in
                        Label(p.label, systemImage: p.symbolIcon).tag(p)
                    }
                }
                .onChange(of: provider) { _ in
                    modelID = provider.presetModelIDs.first ?? ""
                }

                if !provider.presetModelIDs.isEmpty {
                    Picker("Model", selection: $modelID) {
                        ForEach(provider.presetModelIDs, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                }
                if provider.presetModelIDs.isEmpty || modelID == "custom" {
                    TextField("Model ID", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                }

                TextField("Name", text: $displayName, prompt: Text("Optional"))
                    .textFieldStyle(.roundedBorder)

                if provider.requiresAPIKey {
                    APIKeyField(label: "API Key",
                                text: $apiKey,
                                visible: $apiKeyVisible)
                    if let url = provider.apiKeyURL {
                        Link("Get a \(provider.label) key →", destination: url)
                            .font(.system(size: 11))
                    }
                } else if provider == .ollama {
                    Text("No API key needed — Ollama runs locally. Make sure `ollama serve` is running.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canCommit == false)
            }
        }
        .onAppear {
            if modelID.isEmpty {
                modelID = provider.presetModelIDs.first ?? ""
            }
            // Pre-fill API key if we already have one for this provider.
            apiKey = (try? KeychainStore.string(forKey: provider.apiKeyKeychainKey)) ?? ""
        }
        .onChange(of: provider) { _ in
            apiKey = (try? KeychainStore.string(forKey: provider.apiKeyKeychainKey)) ?? ""
        }
    }

    private var canCommit: Bool {
        let trimmedModel = modelID.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty, trimmedModel != "custom" else { return false }
        if provider.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private func commit() {
        let model = ConfiguredModel(
            provider: provider,
            modelID: modelID.trimmingCharacters(in: .whitespaces),
            displayName: displayName.trimmingCharacters(in: .whitespaces)
        )
        onSave(model, apiKey)
    }
}
