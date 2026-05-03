import Foundation
import CryptoKit

/// Generic POST-with-HMAC webhook. Called from `HermesIntegration` and any
/// user-defined webhook. HMAC-SHA256 of the raw body, hex-encoded, sent in
/// `X-Webhook-Signature`.
struct OutboundWebhook {

    let url: URL
    let secret: String?
    let extraHeaders: [String: String]

    init(url: URL, secret: String? = nil, extraHeaders: [String: String] = [:]) {
        self.url = url
        self.secret = secret
        self.extraHeaders = extraHeaders
    }

    /// Sends `body` as the request body. Returns the HTTP status code.
    /// Throws on transport error.
    @discardableResult
    func post(body: Data, contentType: String = "application/json") async throws -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("SolWhisper/0.4", forHTTPHeaderField: "User-Agent")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        if let secret, !secret.isEmpty {
            req.setValue(Self.sign(body: body, secret: secret),
                          forHTTPHeaderField: "X-Webhook-Signature")
        }
        req.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// HMAC-SHA256, lowercase hex.
    static func sign(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
