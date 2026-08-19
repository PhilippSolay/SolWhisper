import Foundation

/// Minimal MCP server speaking JSON-RPC 2.0 over stdin/stdout. We don't
/// pull in a Swift MCP SDK because the surface is tiny and we want zero
/// dependencies in the CLI binary (smaller, faster startup, easier to
/// audit).
///
/// Stdio framing: the spec uses **line-delimited JSON** (one JSON message
/// per line, no Content-Length headers). Easier than HTTP-style framing.
final class MCPServer {

    private let storage = MCPStorage()
    private var initialized = false

    /// Hard cap on a single JSON-RPC line. Without it a malicious or buggy
    /// client could stream an unbounded line and exhaust memory before we ever
    /// parse it. 1 MB is far above any legitimate request.
    private static let maxLineBytes = 1_048_576

    /// Expected token, written by the app to
    /// `~/Library/Application Support/SolWhisper/mcp-token` when MCP is enabled.
    /// The MCP client must pass a matching `SOLWHISPER_MCP_TOKEN` env var, so a
    /// random local process can't spawn this binary and read every transcript
    /// without the user first enabling MCP and copying the token into its config.
    private lazy var expectedToken: String? = Self.readAppToken()

    private var isAuthorized: Bool {
        guard let expected = expectedToken, !expected.isEmpty else { return false }
        return ProcessInfo.processInfo.environment["SOLWHISPER_MCP_TOKEN"] == expected
    }

    private static func readAppToken() -> String? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("SolWhisper/mcp-token")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func run() {
        // Don't buffer output; the parent expects messages immediately.
        setbuf(stdout, nil)

        let stdin = FileHandle.standardInput
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var skipping = false   // dropping an oversize line until its terminating newline

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }   // EOF

            if skipping {
                guard let nl = chunk.firstIndex(of: newline) else { continue }
                buffer = chunk.subdata(in: chunk.index(after: nl)..<chunk.endIndex)
                skipping = false
            } else {
                buffer.append(chunk)
            }

            while let nl = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
                processLine(lineData)
            }

            // A single line that never terminates must not grow without bound.
            if buffer.count > Self.maxLineBytes {
                sendError(id: nil, code: -32600,
                          message: "Request line exceeds \(Self.maxLineBytes)-byte limit; dropped.")
                buffer.removeAll(keepingCapacity: false)
                skipping = true
            }
        }

        // Final line at EOF without a trailing newline (if within bounds).
        if !buffer.isEmpty && buffer.count <= Self.maxLineBytes {
            processLine(buffer)
        }
    }

    /// Decodes one raw line and dispatches it. Empty / whitespace-only lines are
    /// ignored; non-UTF8 lines get a parse error.
    private func processLine(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let line = String(data: data, encoding: .utf8) else {
            sendError(id: nil, code: -32700, message: "Parse error")
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        handle(trimmed)
    }

    // MARK: - Dispatch

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendError(id: nil, code: -32700, message: "Parse error")
            return
        }
        let id = root["id"]
        let method = root["method"] as? String ?? ""
        let params = root["params"] as? [String: Any] ?? [:]

        // Notifications have no `id` and never get a response.
        let isNotification = id == nil

        // Gate every data-returning method behind the token. `initialize`/`ping`
        // stay open so a misconfigured client connects and gets a clear error.
        let dataMethods: Set<String> = ["tools/list", "tools/call", "resources/list", "resources/read"]
        if dataMethods.contains(method) && !isAuthorized {
            if !isNotification {
                sendError(id: id, code: -32001,
                          message: "Unauthorized. Enable MCP in SolWhisper → Settings → Integrations and set SOLWHISPER_MCP_TOKEN in your MCP client config to the token shown there.")
            }
            return
        }

        switch method {
        case "initialize":
            sendResult(id: id, result: initializeResponse(params: params))
        case "notifications/initialized":
            initialized = true
        case "tools/list":
            sendResult(id: id, result: toolsList())
        case "tools/call":
            handleToolsCall(id: id, params: params)
        case "resources/list":
            sendResult(id: id, result: resourcesList())
        case "resources/read":
            handleResourceRead(id: id, params: params)
        case "ping":
            sendResult(id: id, result: [:])
        default:
            if !isNotification {
                sendError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Initialize

    private func initializeResponse(params: [String: Any]) -> [String: Any] {
        return [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:] as [String: Any],
                "resources": [:] as [String: Any]
            ],
            "serverInfo": [
                "name": "solwhisper-mcp",
                "version": "0.5.0"
            ]
        ]
    }

    // MARK: - Tools

    private func toolsList() -> [String: Any] {
        return ["tools": MCPTools.all]
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let content = try MCPTools.dispatch(name: name, args: args, storage: storage)
            sendResult(id: id, result: ["content": content])
        } catch {
            sendError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    // MARK: - Resources

    private func resourcesList() -> [String: Any] {
        return ["resources": storage.listResources()]
    }

    private func handleResourceRead(id: Any?, params: [String: Any]) {
        let uri = params["uri"] as? String ?? ""
        do {
            let contents = try storage.readResource(uri: uri)
            sendResult(id: id, result: ["contents": contents])
        } catch {
            sendError(id: id, code: -32002, message: error.localizedDescription)
        }
    }

    // MARK: - JSON-RPC plumbing

    private func sendResult(id: Any?, result: Any) {
        guard let id = id else { return }   // skip if it was a notification
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { msg["id"] = id } else { msg["id"] = NSNull() }
        send(msg)
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
