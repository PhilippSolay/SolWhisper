import XCTest
@testable import SolWhisper

/// `IntegrationURL.validated` -- the scheme gate shared by Hermes, Kiros, and
/// custom webhooks. Requires https so transcripts never egress in cleartext,
/// with an explicit loopback-http exception for local ingest endpoints.
final class IntegrationURLTests: XCTestCase {

    func testAcceptsHTTPS() throws {
        let url = try IntegrationURL.validated("https://hooks.example.com/ingest")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "hooks.example.com")
    }

    func testTrimsSurroundingWhitespace() throws {
        let url = try IntegrationURL.validated("  https://example.com/x\n")
        XCTAssertEqual(url.host, "example.com")
    }

    func testRejectsCleartextHTTPToRemoteHost() {
        XCTAssertThrowsError(try IntegrationURL.validated("http://example.com/ingest")) { error in
            XCTAssertEqual(error as? IntegrationURL.ValidationError,
                           .insecureScheme("http://example.com/ingest"))
        }
    }

    func testAllowsLoopbackHTTP() {
        XCTAssertNoThrow(try IntegrationURL.validated("http://localhost:8787/hook"))
        XCTAssertNoThrow(try IntegrationURL.validated("http://127.0.0.1:8787/hook"))
    }

    func testAllowsLoopbackHTTPCaseInsensitiveHost() {
        XCTAssertNoThrow(try IntegrationURL.validated("http://LOCALHOST/hook"))
    }

    func testRejectsNonHTTPSchemes() {
        for bad in ["ftp://example.com", "file:///etc/passwd", "javascript:alert(1)"] {
            XCTAssertThrowsError(try IntegrationURL.validated(bad), "\(bad) must be rejected")
        }
    }

    func testRejectsMalformed() {
        XCTAssertThrowsError(try IntegrationURL.validated(""))
        XCTAssertThrowsError(try IntegrationURL.validated("not a url"))
        XCTAssertThrowsError(try IntegrationURL.validated("https://"))
    }
}
