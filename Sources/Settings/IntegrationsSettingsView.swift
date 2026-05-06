import SwiftUI

struct IntegrationsSettingsView: View {

    @AppStorage("hermesEnabled")            private var hermesEnabled = false
    @AppStorage("hermesURL")                private var hermesURL     = ""
    @AppStorage("hermesIncludeTranscript")  private var hermesIncludeTranscript = true
    @AppStorage("hermesIncludeSummary")     private var hermesIncludeSummary = true

    @AppStorage("obsidianEnabled")          private var obsidianEnabled = false
    @AppStorage("obsidianVaultPath")        private var obsidianVaultPath = ""
    @AppStorage("obsidianFolder")           private var obsidianFolder = "Calls"
    @AppStorage("obsidianFilenameTemplate") private var obsidianTemplate = "{{date}}-{{slug}}.md"
    @AppStorage("obsidianIncludeAudioLink") private var obsidianAudio = true

    @StateObject private var customWebhooks = CustomWebhookStore.shared
    @State private var editingWebhook: CustomWebhook?
    @State private var showAddSheet = false

    @State private var hermesSecret: String = ""
    @State private var hermesSecretVisible = false

    var body: some View {
        Form {
            Section {
                MCPCard()
            } header: { Text("MCP server") } footer: {
                Text("Lets MCP-aware AI assistants (Claude Desktop, Cursor, Zed) query your meetings, transcripts, dictation history, and skills. Spawned by the client over stdio — no network port, no exposure beyond the parent process.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Enabled", isOn: $hermesEnabled)
                TextField("Webhook URL", text: $hermesURL)
                    .textFieldStyle(.roundedBorder)
                APIKeyField(label: "HMAC secret",
                            text: Binding(
                                get: { hermesSecret },
                                set: { newValue in
                                    hermesSecret = newValue
                                    try? KeychainStore.set(newValue, forKey: "hermesSecret")
                                }
                            ),
                            visible: $hermesSecretVisible)
                Toggle("Include transcript markdown", isOn: $hermesIncludeTranscript)
                Toggle("Include summary markdown",    isOn: $hermesIncludeSummary)
            } header: { Text("Hermes (your VPS)") } footer: {
                Text("POST JSON to webhook URL with HMAC-SHA256 signature in `X-Webhook-Signature`. Stored in Keychain.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Enabled", isOn: $obsidianEnabled)
                HStack {
                    TextField("Vault path", text: $obsidianVaultPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { pickVaultFolder() }
                }
                TextField("Subfolder",          text: $obsidianFolder)
                    .textFieldStyle(.roundedBorder)
                TextField("Filename template",  text: $obsidianTemplate)
                    .textFieldStyle(.roundedBorder)
                Toggle("Include audio link",    isOn: $obsidianAudio)
            } header: { Text("Obsidian") } footer: {
                Text("Writes a Markdown note per meeting into `<vault>/<subfolder>/`. `{{date}}`, `{{slug}}`, `{{title}}` are supported.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                if customWebhooks.webhooks.isEmpty {
                    Text("No custom webhooks yet.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(customWebhooks.webhooks) { hook in
                        WebhookRow(webhook: hook,
                                   onEdit: { editingWebhook = hook },
                                   onToggle: { var h = hook; h.enabled.toggle(); customWebhooks.update(h) },
                                   onDelete: { customWebhooks.delete(hook) })
                    }
                }
                Button {
                    editingWebhook = CustomWebhook(name: "New webhook")
                    showAddSheet = true
                } label: {
                    Label("Add custom webhook…", systemImage: "plus.circle")
                }
            } header: { Text("Custom webhooks") } footer: {
                Text("POST a templated JSON payload to any URL. HMAC-SHA256 signature in `X-Webhook-Signature` if a secret is set. Mustache placeholders: `{{title}}`, `{{date}}`, `{{summary_markdown}}`, `{{transcript_markdown}}`, etc.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .onAppear {
            hermesSecret = (try? KeychainStore.string(forKey: "hermesSecret")) ?? ""
        }
        .sheet(item: $editingWebhook) { hook in
            WebhookEditorSheet(webhook: hook,
                                isNew: showAddSheet,
                                onSave: { saved in
                                    if showAddSheet { customWebhooks.add(saved) }
                                    else            { customWebhooks.update(saved) }
                                    editingWebhook = nil
                                    showAddSheet = false
                                },
                                onCancel: {
                                    editingWebhook = nil
                                    showAddSheet = false
                                })
        }
    }

    private func pickVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            obsidianVaultPath = url.path
        }
    }
}

private struct WebhookRow: View {
    let webhook: CustomWebhook
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { webhook.enabled },
                                     set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 1) {
                Text(webhook.name).font(.system(size: 13, weight: .medium))
                Text(webhook.urlString.isEmpty ? "(no URL)" : webhook.urlString)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 12))
            }.buttonStyle(.plain)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12))
            }.buttonStyle(.plain)
        }
    }
}

private struct WebhookEditorSheet: View {
    @State var webhook: CustomWebhook
    @State private var secret: String = ""
    @State private var headersText: String = ""
    let isNew: Bool
    let onSave: (CustomWebhook) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $webhook.name)
                TextField("URL", text: $webhook.urlString)
                Toggle("Enabled", isOn: $webhook.enabled)
            } header: { Text("Endpoint") }

            Section {
                APIKeyField(label: "HMAC secret",
                            text: $secret,
                            visible: .constant(false))
                Text("Stored in Keychain. Sent as `X-Webhook-Signature` (HMAC-SHA256, hex).")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("Auth") }

            Section {
                TextEditor(text: $headersText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 60)
                Text("One per line: `Header-Name: value`")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("Custom headers") }

            Section {
                TextEditor(text: $webhook.payloadTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
                Text("Mustache placeholders: {{id}}, {{title}}, {{date}}, {{duration_seconds}}, {{source}}, {{summary_markdown}}, {{transcript_markdown}}.")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("Payload template") }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(webhook.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || webhook.urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            secret = (try? KeychainStore.string(forKey: webhook.keychainKey)) ?? ""
            headersText = webhook.headers
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    private func commit() {
        var saved = webhook
        // Parse headers from textarea: each non-empty line "Key: value"
        var parsed: [String: String] = [:]
        for line in headersText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { parsed[k] = v }
        }
        saved.headers = parsed
        try? KeychainStore.set(secret, forKey: saved.keychainKey)
        onSave(saved)
    }
}
