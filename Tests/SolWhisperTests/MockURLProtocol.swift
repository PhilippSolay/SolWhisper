import Foundation

/// Test-only `URLProtocol` that intercepts every request on a session it's
/// registered with and answers from `handler`. Lets client tests assert on the
/// outgoing request and return canned responses — no real network.
///
/// Use via an ephemeral session:
///     let cfg = URLSessionConfiguration.ephemeral
///     cfg.protocolClasses = [MockURLProtocol.self]
///     let session = URLSession(configuration: cfg)
final class MockURLProtocol: URLProtocol {
    /// Receives the outgoing request, returns (response, body). Throw to simulate
    /// a transport failure. Set before each test; cleared in tearDown.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession moves `httpBody` into `httpBodyStream` before a request reaches a
    /// `URLProtocol`, so tests must read the stream to inspect a POST body.
    var capturedBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
