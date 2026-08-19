import SwiftUI

/// Renamed + restructured from the old `LLMSettingsView`. Routing on top,
/// configured providers below, and a footer of API-key resource links.
/// "+ Add custom model" stub for v0.5.
struct ModelsSettingsView: View {

    @EnvironmentObject private var secrets: SecretsStore

    // STT engines — moved here from the old STT Short / STT Meetings tabs.
    // The Deepgram key lives in Keychain (via SecretsStore), not @AppStorage.
    @AppStorage("transcriptionBackend")     private var shortBackend      = "apple"
    @AppStorage("whisperKitModel")          private var whisperKitModel   = WhisperKitClient.defaultModel
    @AppStorage("meetingsBackend")          private var meetingsBackend   = "whisperkit"
    @AppStorage("meetingsWhisperKitModel")  private var meetingsWKModel   = WhisperKitClient.defaultModel

    @AppStorage("dictationLLMProvider")    private var dictationProvider    = "openrouter"
    @AppStorage("cleanupLLMProvider")      private var cleanupProvider      = "openrouter"
    @AppStorage("summaryLLMProvider")      private var summaryProvider      = "openrouter"
    @AppStorage("translationLLMProvider")  private var translationProvider  = "openrouter"

    // Diarization — engine choice + cloud API key (Deepgram reuses the
    // existing STT key; AssemblyAI gets its own Keychain entry).
    @AppStorage("diarizationEngine") private var diarizationEngine = ""
    @State private var assemblyAIApiKey: String = ""
    @State private var assemblyAIVisible: Bool = false

    @StateObject private var modelStore = ModelStore.shared
    @State private var deepgramVisible = false
    @State private var showAddSheet = false
    @State private var editingModel: ConfiguredModel?

    var body: some View {
        Form {
            // A Keychain write can fail silently (locked keychain, denied
            // access) — surface it so the user doesn't believe a key saved
            // when it didn't.
            if let writeError = secrets.lastWriteError {
                Section {
                    Label(writeError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            // Speech-to-text engines for both modes.
            Section {
                Picker("Dictation", selection: $shortBackend) {
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
                                text: $secrets.deepgramApiKey,
                                visible: $deepgramVisible)
                case "whisperkit":
                    WhisperKitModelPicker(title: "WhisperKit model", modelID: $whisperKitModel)
                default:
                    EmptyView()
                }
            } header: { Text("Dictation engine") }

            Section {
                Picker("Meetings", selection: $meetingsBackend) {
                    Text("WhisperKit  (offline)").tag("whisperkit")
                }
                switch meetingsBackend {
                case "whisperkit":
                    WhisperKitModelPicker(title: "WhisperKit model", modelID: $meetingsWKModel)
                default:
                    EmptyView()
                }
            } header: { Text("Meetings engine") } footer: {
                Text("Apple Speech and Deepgram are mic-only / streaming-only and can't transcribe pre-recorded meeting audio. WhisperKit runs on-device and accepts file URLs.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Engine", selection: $diarizationEngine) {
                    Text("Off").tag("")
                    ForEach(DiarizationResolver.allProviders, id: \.id) { p in
                        Text(p.label).tag(p.id)
                    }
                }
                if diarizationEngine == "assemblyai" {
                    APIKeyField(label: "AssemblyAI API Key",
                                text: $assemblyAIApiKey,
                                visible: $assemblyAIVisible)
                        .onChange(of: assemblyAIApiKey) { newValue in
                            try? KeychainStore.set(newValue,
                                forKey: AssemblyAIDiarizer.apiKeyKeychainKey)
                        }
                    Link("Get an AssemblyAI key →",
                         destination: URL(string: "https://www.assemblyai.com/dashboard/signup")!)
                        .font(.system(size: 11))
                }
                if diarizationEngine == "deepgram" {
                    APIKeyField(label: "Deepgram API Key",
                                text: $secrets.deepgramApiKey,
                                visible: $deepgramVisible)
                    Text("Reuses the same key as Dictation → Deepgram if you have one set.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if diarizationEngine == "fluidaudio" {
                    Text("Local diarization (FluidAudio CoreML) ships in v0.6 — Swift package integration pending. Pick AssemblyAI or Deepgram for now.")
                        .font(.caption).foregroundColor(.orange)
                }
            } header: { Text("Label speakers") } footer: {
                Text("Adds [Speaker A] / [Speaker B] labels to transcript segments. Cloud engines send the audio file to the provider; FluidAudio runs fully on-device (v0.6). Off = no speaker labels (live recordings still use channel-based [Me]/[Other]).")
                    .font(.caption).foregroundColor(.secondary)
            }
            .onAppear {
                assemblyAIApiKey = (try? KeychainStore.string(forKey: AssemblyAIDiarizer.apiKeyKeychainKey)) ?? ""
            }

            // LLM routing — picks WHICH configured model handles each role.
            // Listed before "Configured models" so the user immediately sees
            // what's actually being used.
            Section {
                routingPicker("Dictation cleanup", selection: $dictationProvider)
                routingPicker("Meeting cleanup",   selection: $cleanupProvider)
                routingPicker("Meeting summary",   selection: $summaryProvider)
                routingPicker("Translation",       selection: $translationProvider)
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
                            onEdit: { editingModel = m },
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
        .onAppear {
            // Parakeet was a "coming soon" stub, removed for launch. Migrate any
            // persisted selection to the engine the app actually falls back to,
            // so the picker never shows a blank (unmatched-tag) selection.
            if shortBackend == "parakeet" { shortBackend = "apple" }
            if meetingsBackend == "parakeet" { meetingsBackend = "whisperkit" }
        }
        .sheet(isPresented: $showAddSheet) {
            AddModelSheet(editing: nil,
                          onSave: { newModel, apiKey in
                              if !apiKey.isEmpty {
                                  saveProviderKey(apiKey, forKey: newModel.provider.apiKeyKeychainKey)
                              }
                              modelStore.add(newModel)
                              showAddSheet = false
                          },
                          onCancel: { showAddSheet = false })
        }
        .sheet(item: $editingModel) { m in
            AddModelSheet(editing: m,
                          onSave: { updated, apiKey in
                              // Provider key is shared, so writing the same
                              // key back is a no-op when unchanged. Empty
                              // skips the write so existing keys aren't
                              // wiped if the user blanked the field.
                              if !apiKey.isEmpty {
                                  saveProviderKey(apiKey, forKey: updated.provider.apiKeyKeychainKey)
                              }
                              modelStore.update(updated)
                              editingModel = nil
                          },
                          onCancel: { editingModel = nil })
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

    /// Saves a provider API key, surfacing a Keychain write failure through the
    /// shared error banner (SecretsStore.lastWriteError) instead of silently
    /// dropping it — otherwise a user believes a key saved when it didn't.
    private func saveProviderKey(_ key: String, forKey keychainKey: String) {
        do {
            try KeychainStore.set(key, forKey: keychainKey)
            secrets.lastWriteError = nil
        } catch {
            secrets.lastWriteError = "Couldn't save the API key to the Keychain: \(error.localizedDescription)"
        }
    }
}

// MARK: - Row

private struct ConfiguredModelRow: View {
    let model: ConfiguredModel
    let onEdit: () -> Void
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

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Edit model + API key")
            .accessibilityLabel("Edit model")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Remove from list")
            .accessibilityLabel("Delete model")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add Model sheet

private struct AddModelSheet: View {
    /// Pre-filled when editing an existing model; nil when adding a new one.
    let editing: ConfiguredModel?
    /// Returns `(updated/new model, api-key-to-store)`. When editing, the
    /// model's `id` is preserved by the caller via the captured original.
    let onSave: (ConfiguredModel, String) -> Void
    let onCancel: () -> Void

    @State private var provider: ModelProvider
    @State private var modelID: String
    @State private var displayName: String
    @State private var apiKey: String
    @State private var apiKeyVisible: Bool

    init(editing: ConfiguredModel? = nil,
         onSave: @escaping (ConfiguredModel, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.editing = editing
        self.onSave = onSave
        self.onCancel = onCancel
        if let m = editing {
            _provider = State(initialValue: m.provider)
            _modelID = State(initialValue: m.modelID)
            _displayName = State(initialValue: m.displayName)
        } else {
            _provider = State(initialValue: .anthropic)
            _modelID = State(initialValue: "")
            _displayName = State(initialValue: "")
        }
        _apiKey = State(initialValue: "")          // populated in onAppear
        _apiKeyVisible = State(initialValue: false)
    }

    var body: some View {
        Form {
            Section {
                Text(editing == nil ? "Bring your own keys" : "Edit model")
                    .font(.system(size: 14, weight: .semibold))
                Text(editing == nil
                     ? "Configure a model that uses your own API key to connect directly to a provider."
                     : "Update the model ID, display name, or API key. Provider can't change — delete and re-add to switch providers.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases, id: \.self) { p in
                        Label(p.label, systemImage: p.symbolIcon).tag(p)
                    }
                }
                .disabled(editing != nil)
                .onChange(of: provider) { _ in
                    modelID = provider.presetModelIDs.first ?? ""
                }

                if !provider.presetModelIDs.isEmpty {
                    // Show "Custom…" as the selected option when the current
                    // modelID isn't in the preset list (e.g. an older entry).
                    let isCustom = !provider.presetModelIDs.contains(modelID)
                    Picker("Model", selection: Binding(
                        get: { isCustom ? "custom" : modelID },
                        set: { if $0 != "custom" { modelID = $0 } }
                    )) {
                        ForEach(provider.presetModelIDs, id: \.self) { Text($0).tag($0) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }
                    if isCustom {
                        TextField("Model ID", text: $modelID)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
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
                Button(editing == nil ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canCommit == false)
            }
        }
        .onAppear {
            if modelID.isEmpty {
                modelID = provider.presetModelIDs.first ?? ""
            }
            // Pre-fill API key from Keychain. Provider keys are shared across
            // models from the same provider, so when editing we still surface
            // whatever's currently stored.
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
        // When editing, preserve the original UUID so any routing pickers
        // pinned to this model keep working.
        let id = editing?.id ?? UUID()
        let model = ConfiguredModel(
            id: id,
            provider: provider,
            modelID: modelID.trimmingCharacters(in: .whitespaces),
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            isFavorite: editing?.isFavorite ?? false
        )
        onSave(model, apiKey)
    }
}
