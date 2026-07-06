import Foundation

enum KirosClientError: Error, Equatable {
    case unauthorized           // 401 — bad/absent bearer token
    case rateLimited            // 429
    case http(Int)              // other non-2xx
    case decoding               // body didn't match the contract
    case transport(String)      // URLSession-level failure
}

/// Thin HTTP client for the Kiros ingest contract (frozen in
/// `Kiros/docs/solwhisper-ingest.md`). Bearer auth via the `Authorization` header;
/// the token never leaves the Keychain except into this header at call time.
///
/// `session` is injectable so tests drive it through a `URLProtocol` mock with no
/// real network. Production passes the default `.shared`.
struct KirosClient {
    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// GET /api/ingest/fronts — the user's company/front taxonomy.
    func fetchFronts() async throws -> KirosFrontsResponse {
        let data = try await send(request(path: "/api/ingest/fronts", method: "GET", body: nil))
        return try decode(KirosFrontsResponse.self, from: data)
    }

    /// POST /api/ingest/tasks — file structured tasks into the inbox.
    @discardableResult
    func postTasks(_ payload: KirosIngestRequest) async throws -> KirosIngestResponse {
        let body = try JSONEncoder().encode(payload)
        let data = try await send(request(path: "/api/ingest/tasks", method: "POST", body: body))
        return try decode(KirosIngestResponse.self, from: data)
    }

    // MARK: - internals

    private func url(forPath path: String) -> URL {
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? baseURL
    }

    private func request(path: String, method: String, body: Data?) -> URLRequest {
        var req = URLRequest(url: url(forPath: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        req.setValue("SolWhisper/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw KirosClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KirosClientError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299: return data
        case 401:       throw KirosClientError.unauthorized
        case 429:       throw KirosClientError.rateLimited
        default:        throw KirosClientError.http(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw KirosClientError.decoding }
    }
}
