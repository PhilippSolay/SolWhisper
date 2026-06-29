import XCTest
@testable import SolWhisper

/// `KirosClient` against a `URLProtocol` mock — asserts the outgoing request
/// matches the frozen contract (URL, method, bearer header, body) and maps
/// status codes to typed errors. No real network.
final class KirosClientTests: XCTestCase {

    private func makeClient(token: String = "tok_123") -> KirosClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return KirosClient(baseURL: URL(string: "https://kairos.solay.cloud")!,
                           token: token,
                           session: URLSession(configuration: cfg))
    }

    private func ok(_ json: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             json.data(using: .utf8)!)
        }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPostTasksSendsContractRequest() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let body = #"{"ok":true,"created":1,"skipped":0,"results":[{"idx":0,"status":"created"}]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    body.data(using: .utf8)!)
        }
        let payload = KirosIngestRequest(source: "solwhisper", meetingId: "m1",
                                         meetingTitle: "Call", capturedAt: "2026-06-29T10:00:00Z",
                                         tasks: [KirosTask(idx: 0, title: "Send quote")])
        let resp = try await makeClient().postTasks(payload)

        XCTAssertEqual(resp.created, 1)
        XCTAssertEqual(resp.results.first?.status, "created")

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://kairos.solay.cloud/api/ingest/tasks")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok_123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let sentBody = try XCTUnwrap(req.capturedBody)
        let decoded = try JSONDecoder().decode(KirosIngestRequest.self, from: sentBody)
        XCTAssertEqual(decoded.meetingId, "m1")
        XCTAssertEqual(decoded.tasks.first?.title, "Send quote")
    }

    func testFetchFrontsParsesTaxonomy() async throws {
        MockURLProtocol.handler = ok(#"""
        {"ok":true,"companies":["Acme Studio"],
         "fronts":[{"code":"AS-SALE","name":"Sales","company":"Acme Studio","importance":4}]}
        """#)
        let resp = try await makeClient().fetchFronts()
        XCTAssertEqual(resp.companies, ["Acme Studio"])
        XCTAssertEqual(resp.fronts.first?.code, "AS-SALE")
    }

    func testUnauthorizedMapsToTypedError() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertThrows(.unauthorized) { try await self.makeClient().fetchFronts() }
    }

    func testRateLimitedMapsToTypedError() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertThrows(.rateLimited) { try await self.makeClient().fetchFronts() }
    }

    func testServerErrorMapsToHTTPError() async {
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await assertThrows(.http(500)) { try await self.makeClient().fetchFronts() }
    }

    func testGarbledBodyMapsToDecodingError() async {
        MockURLProtocol.handler = ok("not json")
        await assertThrows(.decoding) { try await self.makeClient().fetchFronts() }
    }

    // MARK: - helper

    private func assertThrows(_ expected: KirosClientError,
                              _ block: @escaping () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await block()
            XCTFail("expected \(expected) but call succeeded", file: file, line: line)
        } catch let error as KirosClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected KirosClientError.\(expected), got \(error)", file: file, line: line)
        }
    }
}
