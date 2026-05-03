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
        didSet {
            if oldValue == openRouterApiKey { return }
            do {
                try KeychainStore.set(openRouterApiKey, forKey: Keys.openRouterApiKey)
            } catch {
                Task { @MainActor in
                    DebugLog.shared.log(icon: "🔐", label: "Keychain write failed",
                                        value: "\(Keys.openRouterApiKey): \(error)", ok: false)
                }
            }
        }
    }

    enum Keys {
        static let openRouterApiKey = "openRouterApiKey"
    }

    init() {
        let stored = (try? KeychainStore.string(forKey: Keys.openRouterApiKey)) ?? ""
        self.openRouterApiKey = stored
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
        let key = Keys.openRouterApiKey
        let defaults = UserDefaults.standard

        guard let legacy = defaults.string(forKey: key), !legacy.isEmpty else {
            return
        }

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
                                        value: "\(error)", ok: false)
                }
                return
            }
        }

        defaults.removeObject(forKey: key)
    }
}
