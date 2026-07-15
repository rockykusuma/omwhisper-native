import Testing
import Foundation
import Security
@testable import OmWhisper

/// These MUST only ever touch `testAccount`.
///
/// They used to call the production accessors (saveAssemblyAIKey, deleteSarvamKey,
/// deleteCloudLLMKey…), and the test host IS the app — so `Keychain.service`
/// resolved to the real bundle ID and every `xcodebuild test` run silently deleted
/// the user's actual API keys from their login keychain. Found 2026-07-15 when the
/// AssemblyAI/Sarvam/cloud keys kept vanishing while ElevenLabs (the one account no
/// test named) survived.
///
/// Coverage is unchanged: every named accessor is a one-line delegate to the
/// generic core exercised here, so testing the core tests all of them.
@Suite("Keychain", .serialized)
struct KeychainTests {
    /// Never a real account name. Real keys live at "assemblyai-api-key",
    /// "sarvam-api-key", "cloud-llm-api-key", "<provider>-api-key".
    private let testAccount = "unit-test-only-key"

    init() throws {
        try? Keychain.delete(account: testAccount)
    }

    @Test("round-trips a saved key")
    func roundTrip() throws {
        try Keychain.save("test-key-123", account: testAccount)
        #expect(Keychain.load(account: testAccount) == "test-key-123")
        try Keychain.delete(account: testAccount)
        #expect(Keychain.load(account: testAccount) == nil)
    }

    @Test("load returns nil when nothing is saved")
    func loadWhenEmpty() {
        #expect(Keychain.load(account: testAccount) == nil)
    }

    @Test("save overwrites an existing key")
    func overwrite() throws {
        try Keychain.save("first", account: testAccount)
        try Keychain.save("second", account: testAccount)
        #expect(Keychain.load(account: testAccount) == "second")
        try Keychain.delete(account: testAccount)
    }

    @Test("delete is a no-op when nothing is saved")
    func deleteWhenEmpty() throws {
        try Keychain.delete(account: testAccount)
    }

    @Test("save recovers over a pre-existing leftover item at the account")
    func recoversOverExistingItem() throws {
        // A leftover item already occupies the account (the field bug was an
        // unreadable one from a differently-signed build; the portable stand-in
        // here is a data-less item). Saving must cope rather than choke.
        let service = Bundle.main.bundleIdentifier ?? "com.omwhisper.mac"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: testAccount,
        ]
        SecItemDelete(base as CFDictionary)
        #expect(SecItemAdd(base as CFDictionary, nil) == errSecSuccess)  // leftover exists

        try Keychain.save("recovered-key", account: testAccount)
        #expect(Keychain.load(account: testAccount) == "recovered-key")
        try Keychain.delete(account: testAccount)
    }

    @Test("accounts are independent — one key never clobbers another")
    func accountsAreIndependent() throws {
        let other = testAccount + "-2"
        defer { try? Keychain.delete(account: other) }
        try Keychain.save("aaa", account: testAccount)
        try Keychain.save("bbb", account: other)
        #expect(Keychain.load(account: testAccount) == "aaa")
        #expect(Keychain.load(account: other) == "bbb")
        try Keychain.delete(account: testAccount)
        #expect(Keychain.load(account: other) == "bbb")  // deleting one leaves the other
    }

    /// Guards the actual regression: no production account name may appear in a
    /// test's reach. If a future test hardcodes a real account, this documents why
    /// that's forbidden.
    @Test("test account is not a production account")
    func testAccountIsNotReal() {
        let production = ["assemblyai-api-key", "sarvam-api-key", "cloud-llm-api-key"]
            + CloudProviderKind.allCases.map(\.keychainAccount)
        #expect(!production.contains(testAccount))
    }
}
