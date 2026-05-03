import XCTest
@testable import SolWhisper

final class KeychainStoreTests: XCTestCase {

    private let testKey = "swTestKey-\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainStore.delete(key: testKey)
        super.tearDown()
    }

    func testRoundTripStoreAndRead() throws {
        try KeychainStore.set("hello world", forKey: testKey)
        XCTAssertEqual(try KeychainStore.string(forKey: testKey), "hello world")
    }

    func testReturnsNilForMissingKey() throws {
        let missing = "swTestMissing-\(UUID().uuidString)"
        XCTAssertNil(try KeychainStore.string(forKey: missing))
    }

    func testOverwritesExistingValue() throws {
        try KeychainStore.set("first", forKey: testKey)
        try KeychainStore.set("second", forKey: testKey)
        XCTAssertEqual(try KeychainStore.string(forKey: testKey), "second")
    }

    func testEmptyStringDeletesEntry() throws {
        try KeychainStore.set("temp", forKey: testKey)
        try KeychainStore.set("", forKey: testKey)
        XCTAssertNil(try KeychainStore.string(forKey: testKey))
    }

    func testDeleteIsIdempotent() {
        let absent = "swTestAbsent-\(UUID().uuidString)"
        XCTAssertNoThrow(try KeychainStore.delete(key: absent))
        XCTAssertNoThrow(try KeychainStore.delete(key: absent))
    }
}

@MainActor
final class SecretsStoreMigrationTests: XCTestCase {

    private let key = SecretsStore.Keys.openRouterApiKey

    override func setUp() async throws {
        try await super.setUp()
        try? KeychainStore.delete(key: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() async throws {
        try? KeychainStore.delete(key: key)
        UserDefaults.standard.removeObject(forKey: key)
        try await super.tearDown()
    }

    func testMovesValueFromUserDefaultsIntoKeychainAndRemovesUserDefaultsCopy() throws {
        UserDefaults.standard.set("legacy-key-abc", forKey: key)
        SecretsStore.migrateFromUserDefaultsIfNeeded()

        XCTAssertEqual(try KeychainStore.string(forKey: key), "legacy-key-abc")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testKeychainTakesPrecedenceWhenBothExist() throws {
        try KeychainStore.set("keychain-already-set", forKey: key)
        UserDefaults.standard.set("legacy-shadow", forKey: key)

        SecretsStore.migrateFromUserDefaultsIfNeeded()

        XCTAssertEqual(try KeychainStore.string(forKey: key), "keychain-already-set")
        XCTAssertNil(UserDefaults.standard.string(forKey: key),
                     "Legacy UserDefaults entry must be removed even when Keychain already had a value")
    }

    func testNoOpWhenNothingToMigrate() throws {
        SecretsStore.migrateFromUserDefaultsIfNeeded()
        XCTAssertNil(try KeychainStore.string(forKey: key))
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testMigrationIsIdempotent() throws {
        UserDefaults.standard.set("once", forKey: key)
        SecretsStore.migrateFromUserDefaultsIfNeeded()
        SecretsStore.migrateFromUserDefaultsIfNeeded()
        XCTAssertEqual(try KeychainStore.string(forKey: key), "once")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }
}
