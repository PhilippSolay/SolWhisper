import XCTest
@testable import SolWhisper

/// The streaming URL is the whole language contract with Deepgram — assert it
/// without opening a socket.
final class DeepgramClientTests: XCTestCase {

    private func queryItems(for language: String) -> [String: String] {
        let url = DeepgramClient.streamURL(language: language)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] { result[item.name] = item.value }
        return result
    }

    func testStreamURLTargetsNova3Streaming() {
        let url = DeepgramClient.streamURL(language: "en-US")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.deepgram.com")
        XCTAssertEqual(url.path, "/v1/listen")
        XCTAssertEqual(queryItems(for: "en-US")["model"], "nova-3")
    }

    func testStreamURLCarriesSelectedLanguage() {
        XCTAssertEqual(queryItems(for: "es")["language"], "es")
        XCTAssertEqual(queryItems(for: "fr-CA")["language"], "fr-CA")
        XCTAssertEqual(queryItems(for: "es-419")["language"], "es-419")
    }

    func testStreamURLKeepsAudioContract() {
        let q = queryItems(for: "de")
        XCTAssertEqual(q["encoding"], "linear16")
        XCTAssertEqual(q["sample_rate"], "16000")
        XCTAssertEqual(q["channels"], "1")
        XCTAssertEqual(q["interim_results"], "true")
        XCTAssertEqual(q["smart_format"], "true")
        XCTAssertEqual(q["endpointing"], "300")
    }
}
