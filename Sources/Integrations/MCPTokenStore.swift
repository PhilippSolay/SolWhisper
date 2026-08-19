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

    // MARK: - Private

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)   // 256 bits
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // Never emit a predictable (all-zero) token. SecRandomCopyBytes
            // failing is near-impossible, but if it ever does we fall back to
            // the platform CSPRNG rather than shipping a guessable MCP token.
            return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ token: String) {
        guard let url = tokenFileURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Create the file 0600 up front. Writing atomically first (a fresh temp
        // file at the umask default of 0644) and only chmod-ing afterwards left
        // a brief window where the token was world-readable.
        let data = Data(token.utf8)
        if !FileManager.default.createFile(atPath: url.path, contents: data,
                                           attributes: [.posixPermissions: 0o600]) {
            // Fallback: write then tighten perms.
            try? data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        }
    }
}
