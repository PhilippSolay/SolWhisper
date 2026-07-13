import XCTest
@testable import SolWhisper

/// Regression tests for the "stuck model download" bug pair:
///   1. `isModelDownloaded` treated a bare variant folder as a finished
///      download, but the Hub downloader fills the folder file-by-file —
///      navigating away mid-download and back showed "✓ available offline"
///      for a half-written model.
///   2. The picker shipped "large-v3-turbo", an ID that never existed in
///      argmaxinc/whisperkit-coreml (the turbo checkpoint is
///      "large-v3-v20240930"), so downloads threw "No models found".
@MainActor
final class WhisperKitModelStateTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-modelstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Lays down a fake variant folder mirroring the Hub repo layout,
    /// optionally with every artifact `isModelDownloaded` requires.
    private func makeModelFolder(named name: String, complete: Bool) throws -> URL {
        let folder = tempRoot
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if complete {
            for artifact in ["MelSpectrogram.mlmodelc/coremldata.bin",
                             "AudioEncoder.mlmodelc/weights/weight.bin",
                             "TextDecoder.mlmodelc/weights/weight.bin",
                             "config.json"] {
                let file = folder.appendingPathComponent(artifact)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("stub".utf8).write(to: file)
            }
        }
        return folder
    }

    // MARK: - Download completeness

    func testEmptyVariantFolderIsNotDownloaded() throws {
        _ = try makeModelFolder(named: "openai_whisper-small.en", complete: false)
        XCTAssertFalse(WhisperKitClient.isModelDownloaded("small.en", in: tempRoot),
                       "A bare variant folder means a download started, not finished")
    }

    func testPartialVariantFolderIsNotDownloaded() throws {
        let folder = try makeModelFolder(named: "openai_whisper-small.en", complete: false)
        let partial = folder.appendingPathComponent("MelSpectrogram.mlmodelc/coremldata.bin")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: partial)
        XCTAssertFalse(WhisperKitClient.isModelDownloaded("small.en", in: tempRoot),
                       "Encoder/decoder weights and config.json are still missing")
    }

    func testCompleteVariantFolderIsDownloaded() throws {
        _ = try makeModelFolder(named: "openai_whisper-small.en", complete: true)
        XCTAssertTrue(WhisperKitClient.isModelDownloaded("small.en", in: tempRoot))
    }

    func testVariantMatchingIsExactNotSubstring() throws {
        // A complete _626MB sibling must NOT satisfy the full-size model —
        // the old contains() heuristic got this wrong.
        _ = try makeModelFolder(named: "openai_whisper-large-v3-v20240930_626MB",
                                complete: true)
        XCTAssertFalse(WhisperKitClient.isModelDownloaded("large-v3-v20240930", in: tempRoot))
        XCTAssertTrue(WhisperKitClient.isModelDownloaded("large-v3-v20240930_626MB", in: tempRoot))
    }

    func testMissingRootIsNotDownloaded() {
        let absent = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertFalse(WhisperKitClient.isModelDownloaded("small.en", in: absent))
    }

    // MARK: - Model IDs

    func testSupportedModelsContainNoInvalidTurboID() {
        XCTAssertFalse(WhisperKitClient.supportedModels.contains("large-v3-turbo"),
                       "large-v3-turbo never existed in argmaxinc/whisperkit-coreml")
        XCTAssertTrue(WhisperKitClient.supportedModels.contains("large-v3-v20240930"))
        XCTAssertTrue(WhisperKitClient.supportedModels.contains("large-v3-v20240930_626MB"))
    }

    func testDisplayNameMapsTurboIDs() {
        XCTAssertEqual(WhisperKitClient.displayName(for: "large-v3-v20240930"),
                       "large-v3-turbo")
        XCTAssertEqual(WhisperKitClient.displayName(for: "large-v3-v20240930_626MB"),
                       "large-v3-turbo (compressed)")
        XCTAssertEqual(WhisperKitClient.displayName(for: "small.en"), "small.en")
    }

    // MARK: - Prefs migration

    func testLegacyTurboPrefsAreMigrated() throws {
        let suiteName = "sw-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("large-v3-turbo", forKey: "whisperKitModel")
        defaults.set("small.en", forKey: "meetingsWhisperKitModel")

        WhisperKitClient.migrateLegacyModelIDs(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "whisperKitModel"), "large-v3-v20240930")
        XCTAssertEqual(defaults.string(forKey: "meetingsWhisperKitModel"), "small.en",
                       "Valid selections must be left untouched")
    }

    func testMigrationIsNoOpWithoutLegacyValue() throws {
        let suiteName = "sw-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WhisperKitClient.migrateLegacyModelIDs(in: defaults)

        XCTAssertNil(defaults.string(forKey: "whisperKitModel"))
        XCTAssertNil(defaults.string(forKey: "meetingsWhisperKitModel"))
    }
}
