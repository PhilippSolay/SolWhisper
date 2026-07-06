import SwiftUI

/// Settings → Integrations card describing the local MCP server, with
/// copy-config buttons for Claude Desktop and Cursor.
struct MCPCard: View {

    @State private var copiedPath: Bool = false
    @State private var copiedClaude: Bool = false
    @State private var copiedCursor: Bool = false
    /// Auth token embedded in the copied config so the MCP server will actually
    /// serve data. Generated (and persisted) the first time this card appears.
    @State private var token: String = ""

    /// The CLI binary is bundled inside SolWhisper.app/Contents/MacOS/.
    /// We look it up at runtime via Bundle.main so the path is correct
    /// regardless of where the user installed the app.
    private var binaryPath: String {
        let appURL = Bundle.main.bundleURL
        return appURL.appendingPathComponent("Contents/MacOS/solwhisper-mcp").path
    }

    private var binaryExists: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    private var claudeSnippet: String {
        return """
        {
          "mcpServers": {
            "solwhisper": {
              "command": "\(binaryPath)",
              "env": { "SOLWHISPER_MCP_TOKEN": "\(token)" }
            }
          }
        }
        """
    }

    private var cursorSnippet: String {
        // Cursor uses the same JSON shape as Claude Desktop.
        return claudeSnippet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(binaryExists ? .green : .orange)
                    .font(.system(size: 14))
                Text(binaryExists ? "Installed" : "Binary not found in app bundle")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: binaryPath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal binary in Finder")
                .disabled(!binaryExists)
            }

            HStack(spacing: 6) {
                Text("Path:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(binaryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(binaryPath, forType: .string)
                    copiedPath = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedPath = false
                    }
                } label: {
                    Image(systemName: copiedPath ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(copiedPath ? "Copied!" : "Copy path")
            }

            Divider().padding(.vertical, 2)

            Text("Add to your AI assistant")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                Button {
                    copyClaude()
                } label: {
                    Label(copiedClaude ? "Copied!" : "Copy Claude Desktop config",
                          systemImage: copiedClaude ? "checkmark" : "doc.on.doc")
                }
                .disabled(!binaryExists)

                Button {
                    copyCursor()
                } label: {
                    Label(copiedCursor ? "Copied!" : "Copy Cursor config",
                          systemImage: copiedCursor ? "checkmark" : "doc.on.doc")
                }
                .disabled(!binaryExists)
            }

            DisclosureGroup("Show config snippet") {
                ScrollView {
                    Text(claudeSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.10))
                )
            }
            .font(.system(size: 11))

            Text("**Claude Desktop config file:** ~/Library/Application Support/Claude/claude_desktop_config.json — paste the snippet inside the `mcpServers` object, then quit and relaunch Claude Desktop. **Cursor:** Settings → MCP, add a new server with the same JSON.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Text("The config includes a private access token. Without it, the server won't share your transcripts — so only an assistant you've configured can read them. Keep the config file private.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear { token = MCPTokenStore.ensureToken() }
    }

    // MARK: - Helpers

    private func copyClaude() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudeSnippet, forType: .string)
        copiedClaude = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedClaude = false
        }
    }

    private func copyCursor() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cursorSnippet, forType: .string)
        copiedCursor = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedCursor = false
        }
    }
}
