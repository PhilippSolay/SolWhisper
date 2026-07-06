import XCTest
@testable import SolWhisper

/// Regression tests for the OpenRouter dual-Keychain-account bug: the Models
/// tab wrote `model.provider.openrouter.apiKey` while the client read the
/// legacy `openRouterApiKey`, so a key set in the Models tab silently failed.
/// See docs/launch-review/02-architecture.md (C2). Tests the pure precedence
/// rule so they never touch the real login Keychain.
final class OpenRouterKeyResolutionTests: XCTestCase {

    func testPrefersProviderKeyWhenSetViaModelsTab() {
        XCTAssertEqual(
            OpenRouterLLMClient.resolveKey(providerKey: "sk-or-provider", legacyKey: ""),
            "sk-or-provider")
    }

    func testFallsBackToLegacyKeyFromOnboarding() {
        XCTAssertEqual(
            OpenRouterLLMClient.resolveKey(providerKey: "", legacyKey: "sk-or-legacy"),
            "sk-or-legacy")
    }

    func testPrefersProviderKeyWhenBothPresent() {
        XCTAssertEqual(
            OpenRouterLLMClient.resolveKey(providerKey: "sk-or-provider", legacyKey: "sk-or-legacy"),
            "sk-or-provider")
    }

    func testEmptyWhenNeitherPresent() {
        XCTAssertEqual(
            OpenRouterLLMClient.resolveKey(providerKey: "", legacyKey: ""),
            "")
    }
}
