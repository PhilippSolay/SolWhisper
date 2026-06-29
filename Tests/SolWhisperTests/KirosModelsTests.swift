import XCTest
@testable import SolWhisper

/// Wire-model round-trips and tolerant decoding for the Kiros ingest contract.
/// A drift here silently mis-files tasks, so the JSON keys are pinned explicitly.
final class KirosModelsTests: XCTestCase {

    func testTaskEncodesContractKeys() throws {
        let task = KirosTask(idx: 0, title: "Send quote", company: "Acme Studio",
                             category: "Sales", project: "Bluebird", front: "AS-SALE",
                             importance: 4, urgency: 5, est: "30m", due: "2026-07-02",
                             energy: "low", avoid: false, taskDescription: "context")
        let data = try JSONEncoder().encode(task)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // `taskDescription` must serialize as the contract key "description".
        XCTAssertEqual(json["description"] as? String, "context")
        XCTAssertNil(json["taskDescription"])
        XCTAssertEqual(json["idx"] as? Int, 0)
        XCTAssertEqual(json["front"] as? String, "AS-SALE")
    }

    func testRequestEnvelopeUsesSnakeCaseKeys() throws {
        let req = KirosIngestRequest(source: "solwhisper", meetingId: "m1",
                                     meetingTitle: "Call", capturedAt: "2026-06-29T10:00:00Z",
                                     tasks: [])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(json["meeting_id"] as? String, "m1")
        XCTAssertEqual(json["meeting_title"] as? String, "Call")
        XCTAssertEqual(json["captured_at"] as? String, "2026-06-29T10:00:00Z")
    }

    func testNullableTaskFieldsOmitOrNull() throws {
        let task = KirosTask(idx: 1, title: "Bare task")
        let decoded = try JSONDecoder().decode(
            KirosTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
        XCTAssertNil(decoded.importance)
        XCTAssertNil(decoded.due)
    }

    func testIngestResponseDecodesFullBody() throws {
        let body = """
        {"ok":true,"created":2,"skipped":1,"results":[
          {"idx":0,"status":"created","front":"AS-SALE","url":"solwhisper:m1:0"},
          {"idx":1,"status":"duplicate","url":"solwhisper:m1:1"}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(KirosIngestResponse.self, from: body)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.created, 2)
        XCTAssertEqual(resp.skipped, 1)
        XCTAssertEqual(resp.results.count, 2)
        XCTAssertEqual(resp.results[1].status, "duplicate")
    }

    func testIngestResponseToleratesMissingFields() throws {
        // Backend drift must not crash the client — missing scalars default.
        let resp = try JSONDecoder().decode(
            KirosIngestResponse.self, from: #"{"ok":true}"#.data(using: .utf8)!)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.created, 0)
        XCTAssertEqual(resp.skipped, 0)
        XCTAssertTrue(resp.results.isEmpty)
    }

    func testFrontsResponseDecodes() throws {
        let body = """
        {"ok":true,"companies":["Acme Studio","Personal"],
         "fronts":[{"code":"AS-SALE","name":"Sales","company":"Acme Studio","importance":4}]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(KirosFrontsResponse.self, from: body)
        XCTAssertEqual(resp.companies, ["Acme Studio", "Personal"])
        XCTAssertEqual(resp.fronts.first?.code, "AS-SALE")
        XCTAssertEqual(resp.fronts.first?.importance, 4)
    }
}
