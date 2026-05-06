import Foundation

/// `solwhisper-mcp` — MCP stdio server.
///
/// Spawned by Claude Desktop / Cursor as a subprocess. Communicates over
/// stdin/stdout using JSON-RPC 2.0 (framed by Content-Length headers, per
/// MCP's stdio transport spec). Reads SolWhisper's on-disk state directly
/// from `~/Library/Application Support/SolWhisper/` — no IPC with the
/// running menu-bar app.
///
/// v1 surface (read-only):
///   - tools/list, tools/call (5 tools)
///   - resources/list, resources/read (3 resources)
///   - initialize, notifications/initialized
///
/// Mutating operations (delete meeting, mark action) come in v0.6.

let server = MCPServer()
server.run()
