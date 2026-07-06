import Foundation
import SwiftUI

/// Holds all user secrets (API keys, webhook HMACs) backed by the Keychain.
///
/// Owned by the app at root scope and passed via `@EnvironmentObject` to any view
/// that needs to read or write a secret. The published string is the in-memory
/// mirror of the Keychain entry; setting it writes through to the Keychain.
@MainActor
final class SecretsStore: ObservableObject {

    @Published var openRouterApiKey: String {
        didSet { writeThrough(openRouterApiKey, oldValue: oldValue, key: Keys.openRouterApiKey) }
    }

    @Published var deepgramApiKey: String {
        didSet { writeThrough(deepgramApiKey, oldValue: oldValue, key: Keys.deepgramApiKey) }
    }

    enum Keys {
        static let openRouterApiKey = "openRouterApiKey"
        static let deepgramApiKey = "deepgramApiKey"

        /// Every secret that migrates from a legacy plaintext UserDefault.
        static let migratable = [openRouterApiKey, deepgramApiKey]
    }

    init() {
        self.openRouterApiKey = (try? KeychainStore.string(forKey: Keys.openRouterApiKey)) ?? ""
        self.deepgramApiKey = (try? KeychainStore.string(forKey: Keys.deepgramApiKey)) ?? ""
    }

    private func writeThrough(_ value: String, oldValue: String, key: String) {
        guard oldValue != value else { return }
        do {
            try KeychainStore.set(value, forKey: key)
        } catch {
            Task { @MainActor in
                DebugLog.shared.log(icon: "🔐", label: "Keychain write failed",
                                    value: "\(key): \(error)", ok: false)
            }
        }
    }

    /// One-shot migration from UserDefaults → Keychain, called once at app
    /// launch (before the first view reads any secret).
    ///
    /// Idempotent: if the Keychain entry already exists, the UserDefaults entry
    /// is removed without overwriting Keychain. If only UserDefaults has the key,
    /// it's copied to Keychain and then deleted.
    ///
    /// Safe to call on every launch — no-op if no UserDefaults entry exists.
    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        for key in Keys.migratable {
            guard let legacy = defaults.string(forKey: key), !legacy.isEmpty else { continue }

            let existing = (try? KeychainStore.string(forKey: key)) ?? ""
            if existing.isEmpty {
                do {
                    try KeychainStore.set(legacy, forKey: key)
                    Task { @MainActor in
                        DebugLog.shared.log(icon: "🔐", label: "Keychain migration",
                                            value: "\(key) moved from UserDefaults")
                    }
                } catch {
                    Task { @MainActor in
                        DebugLog.shared.log(icon: "🔐", label: "Keychain migration failed",
                                            value: "\(key): \(error)", ok: false)
                    }
                    continue   // leave the UserDefaults value in place to retry next launch
                }
            }
            defaults.removeObject(forKey: key)
        }
    }
}
