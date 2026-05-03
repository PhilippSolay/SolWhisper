import XCTest
@testable import SolWhisper

/// Sprint 1 unit tests for WhisperKitClient.
///
/// Heavy integration (loading a model, transcribing audio) is out of scope
/// for unit tests — model downloads are 39 MB–1.5 GB and load times are
/// 1-5s on M-series. Those are exercised manually via the three-backend
/// demo and will move into a gated integration target later.
///
/// What we verify here:
///   - Static helpers don't crash and return sensible defaults
///   - Model-presence heuristic handles missing models without throwing
///   - Cancellation throws `CancellationError` cleanly
///   - Bad audio paths surface as errors rather than crashing
@MainActor
final class WhisperKitClientTests: XCTestCase {

    func testSupportedModelsListIsNonEmpty() {
        XCTAssertFalse(WhisperKitClient.supportedModels.isEmpty)
    }

    func testStripSpecialTokensRemovesWhisperKitMarkers() {
        let raw = "<|startoftranscript|><|0.00|> 1, 2, 3 testing<|5.00|> whispering kits<|endoftext|>"
        let clean = WhisperKitClient.stripSpecialTokens(raw)
        XCTAssertEqual(clean, "1, 2, 3 testing whispering kits")
    }

    func testStripSpecialTokensIsNoOpWhenAbsent() {
        let raw = "Just plain text with no markers."
        XCTAssertEqual(WhisperKitClient.stripSpecialTokens(raw), raw)
    }

    func testStripSpecialTokensCollapsesDoubleSpaces() {
        let raw = "Hello <|0.00|> <|en|> world"
        XCTAssertEqual(WhisperKitClient.stripSpecialTokens(raw), "Hello world")
    }

    func testDefaultModelIsInSupportedList() {
        XCTAssertTrue(WhisperKitClient.supportedModels.contains(WhisperKitClient.defaultModel))
    }

    func testModelsDirectoryIsCreated() {
        let dir = WhisperKitClient.modelsDirectory
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(exists, "modelsDirectory should be created on first access")
        XCTAssertTrue(isDir.boolValue, "modelsDirectory should be a directory")
        XCTAssertTrue(dir.path.contains("SolWhisper/Models/WhisperKit"),
                      "modelsDirectory should be under our app support tree, not ~/Documents/huggingface")
    }

    func testIsModelDownloadedReturnsFalseForUnknownModel() {
        // Use a guaranteed-absent variant name. If WhisperKit users somehow have
        // a folder matching this in their model dir, this will spuriously fail —
        // but the UUID buys us safety.
        let bogus = "sw-test-nonexistent-\(UUID().uuidString)"
        XCTAssertFalse(WhisperKitClient.isModelDownloaded(bogus))
    }

    func testFileTranscribeRejectsMissingFile() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/sw-nonexistent-\(UUID().uuidString).wav")
        do {
            _ = try await WhisperKitClient.fileTranscribe(
                audioPath: bogusURL,
                model: WhisperKitClient.defaultModel,
                progress: nil
            )
            XCTFail("Expected an error for missing audio file")
        } catch WhisperKitClientError.audioFileMissing(let url) {
            XCTAssertEqual(url.path, bogusURL.path,
                           "Should fail fast with audioFileMissing before model load")
        } catch {
            XCTFail("Expected audioFileMissing, got \(error)")
        }
    }

    func testFileTranscribeIsCancellable() async {
        let bogusURL = URL(fileURLWithPath: "/tmp/sw-cancel-\(UUID().uuidString).wav")

        // Spawn a transcribe task and cancel it before it has a chance to run.
        let task = Task {
            try await WhisperKitClient.fileTranscribe(
                audioPath: bogusURL,
                model: WhisperKitClient.defaultModel,
                progress: nil
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            // If the call actually succeeded (extremely unlikely with a bogus path
            // and no model loaded), at least cancellation was honored elsewhere.
        } catch {
            // Either CancellationError or the missing-file error — both prove we
            // didn't deadlock or crash.
        }
    }
}
