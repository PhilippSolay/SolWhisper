import Foundation
import Security

/// Manages the local MCP auth token.
///
/// The bundled `solwhisper-mcp` binary refuses to serve any transcript data
/// unless the calling MCP client passes a `SOLWHISPER_MCP_TOKEN` env var that
/// matches this token. Without it, any local process could spawn the binary and
/// read every meeting transcript. The token lives in a 0600 file under the app's
/// Application Support folder, which the binary reads on startup.
enum MCPTokenStore {

    static var tokenFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SolWhisper", isDirectory: true)
            .appendingPathComponent("mcp-token")
    }

    /// Returns the current token, generating and persisting a fresh one if none
    /// exists yet. Call this when the user is setting up MCP.
    static func ensureToken() -> String {
        if let existing = current() { return existing }
        let token = generate()
        write(token)
        return token
    }

    static func current() -> String? {
        guard let url = tokenFileURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Rotates the token (invalidates any previously-configured client).
    @discardableResult
    static func regenerate() -> String {
        let token = generate()
        write(token)
        return token
    }

    // MARK: - Private

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)   // 256 bits
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ token: String) {
        guard let url = tokenFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? token.write(to: url, atomically: true, encoding: .utf8)
        // Owner read/write only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
