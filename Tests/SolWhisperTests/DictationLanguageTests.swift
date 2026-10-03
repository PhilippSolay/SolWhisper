import XCTest
@testable import SolWhisper

/// Catalog + per-backend readiness for dictation input languages (drives the
/// tray "Input Language" submenu and the Languages settings pane).
///
/// Apple-backend readiness is a thin `SFSpeechRecognizer` probe whose answer
/// depends on which macOS dictation packs this machine has installed — it is
/// deliberately not asserted here.
final class DictationLanguageTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-dictlang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Catalog

    func testCuratedIDsAreUniqueAndParseable() {
        let ids = DictationLanguage.curated.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate language IDs in the catalog")
        for lang in DictationLanguage.curated {
            XCTAssertEqual(Locale(identifier: lang.id).language.languageCode?.identifier,
                           lang.whisperCode,
                           "\(lang.id): locale language code must match the Whisper code")
            XCTAssertFalse(lang.label.isEmpty)
        }
    }

    func testFallbackIsAmericanEnglishAndFirstInCatalog() {
        XCTAssertEqual(DictationLanguage.fallback.id, "en-US")
        XCTAssertEqual(DictationLanguage.curated.first, DictationLanguage.fallback)
    }

    func testWhisperCodeStripsRegion() {
        XCTAssertEqual(DictationLanguage.named("es-ES").whisperCode, "es")
        XCTAssertEqual(DictationLanguage.named("en-GB").whisperCode, "en")
        XCTAssertEqual(DictationLanguage.named("pt-BR").whisperCode, "pt")
    }

    func testDeepgramCodesForRegionalVariants() {
        XCTAssertEqual(DictationLanguage.named("es-MX").deepgramCode, "es-419")
        XCTAssertEqual(DictationLanguage.named("fr-CA").deepgramCode, "fr-CA")
        XCTAssertEqual(DictationLanguage.named("de-DE").deepgramCode, "de")
        XCTAssertEqual(DictationLanguage.named("en-US").deepgramCode, "en-US")
    }

    func testEnglishFlagFollowsPrimarySubtag() {
        XCTAssertTrue(DictationLanguage.named("en-GB").isEnglish)
        XCTAssertFalse(DictationLanguage.named("fr-FR").isEnglish)
    }

    // MARK: - Lookup + persistence

    func testNamedFallsBackForUnknownID() {
        XCTAssertEqual(DictationLanguage.named("xx-XX"), DictationLanguage.fallback)
        XCTAssertEqual(DictationLanguage.named("fr-FR").label, "French (France)")
    }

    func testSelectedReadsDefaultsWithFallback() throws {
        let suiteName = "sw-dictlang-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DictationLanguage.selected(in: defaults), .fallback,
                       "Unset key must fall back to en-US")

        defaults.set("fr-FR", forKey: DictationLanguage.defaultsKey)
        XCTAssertEqual(DictationLanguage.selected(in: defaults).id, "fr-FR")

        defaults.set("not-a-language", forKey: DictationLanguage.defaultsKey)
        XCTAssertEqual(DictationLanguage.selected(in: defaults), .fallback,
                       "Garbage stored value must fall back, not crash the menu")
    }

    // MARK: - Readiness (Deepgram)

    func testDeepgramIsReadyForEveryCuratedLanguage() {
        for lang in DictationLanguage.curated {
            XCTAssertEqual(
                DictationLanguageAvailability.readiness(for: lang, backend: "deepgram"),
                .ready,
                "\(lang.id): cloud backend needs no local assets"
            )
        }
    }

    // MARK: - Readiness (WhisperKit)

    /// Mirrors WhisperKitModelStateTests.makeModelFolder — Hub repo layout
    /// with the artifacts `isModelDownloaded` requires.
    private func makeModelFolder(named name: String) throws {
        let folder = tempRoot
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(name)",
                                    isDirectory: true)
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

    private func makeDefaults(model: String) throws -> UserDefaults {
        let suiteName = "sw-dictlang-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(model, forKey: "whisperKitModel")
        return defaults
    }

    func testWhisperKitEnglishReadyWhenSelectedModelDownloaded() throws {
        try makeModelFolder(named: "openai_whisper-base.en")
        let defaults = try makeDefaults(model: "base.en")
        XCTAssertEqual(
            DictationLanguageAvailability.readiness(
                for: .named("en-US"), backend: "whisperkit",
                defaults: defaults, modelsRoot: tempRoot),
            .ready
        )
    }

    func testWhisperKitNeedsDownloadWhenSelectedModelMissing() throws {
        let defaults = try makeDefaults(model: "base.en")
        XCTAssertEqual(
            DictationLanguageAvailability.readiness(
                for: .named("en-US"), backend: "whisperkit",
                defaults: defaults, modelsRoot: tempRoot),
            .needsDownload
        )
    }

    func testWhisperKitEnglishOnlyModelCannotServeSpanish() throws {
        try makeModelFolder(named: "openai_whisper-base.en")
        let defaults = try makeDefaults(model: "base.en")
        XCTAssertEqual(
            DictationLanguageAvailability.readiness(
                for: .named("es-ES"), backend: "whisperkit",
                defaults: defaults, modelsRoot: tempRoot),
            .needsDownload,
            "A .en decode model can never transcribe Spanish"
        )
    }

    func testWhisperKitMultilingualModelServesSpanishAndFrench() throws {
        try makeModelFolder(named: "openai_whisper-large-v3-v20240930")
        let defaults = try makeDefaults(model: "large-v3-v20240930")
        for id in ["es-ES", "fr-CA", "en-US"] {
            XCTAssertEqual(
                DictationLanguageAvailability.readiness(
                    for: .named(id), backend: "whisperkit",
                    defaults: defaults, modelsRoot: tempRoot),
                .ready,
                "\(id): multilingual model downloaded — should be ready"
            )
        }
    }

    func testWhisperKitBareMultilingualBaseServesSpanish() throws {
        try makeModelFolder(named: "openai_whisper-base")
        let defaults = try makeDefaults(model: "base")
        XCTAssertEqual(
            DictationLanguageAvailability.readiness(
                for: .named("es-ES"), backend: "whisperkit",
                defaults: defaults, modelsRoot: tempRoot),
            .ready
        )
    }
}
