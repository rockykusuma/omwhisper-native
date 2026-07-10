import Testing
@testable import OmWhisper

@Suite("Keychain", .serialized)
struct KeychainTests {
    init() throws {
        try? Keychain.deleteAssemblyAIKey()
    }

    @Test("round-trips a saved key")
    func roundTrip() throws {
        try Keychain.saveAssemblyAIKey("test-key-123")
        #expect(Keychain.loadAssemblyAIKey() == "test-key-123")
        try Keychain.deleteAssemblyAIKey()
    }

    @Test("load returns nil when nothing is saved")
    func loadWhenEmpty() {
        #expect(Keychain.loadAssemblyAIKey() == nil)
    }

    @Test("save overwrites an existing key")
    func overwrite() throws {
        try Keychain.saveAssemblyAIKey("first")
        try Keychain.saveAssemblyAIKey("second")
        #expect(Keychain.loadAssemblyAIKey() == "second")
        try Keychain.deleteAssemblyAIKey()
    }

    @Test("delete is a no-op when nothing is saved")
    func deleteWhenEmpty() throws {
        try Keychain.deleteAssemblyAIKey()
    }

    @Test("cloud-LLM key round-trips independently of the AssemblyAI item")
    func cloudLLMKeyRoundTrip() throws {
        try Keychain.deleteCloudLLMKey()
        #expect(Keychain.loadCloudLLMKey() == nil)
        try Keychain.saveCloudLLMKey("sk-test-123")
        #expect(Keychain.loadCloudLLMKey() == "sk-test-123")
        try Keychain.saveCloudLLMKey("sk-test-456")  // overwrite
        #expect(Keychain.loadCloudLLMKey() == "sk-test-456")
        try Keychain.deleteCloudLLMKey()
        #expect(Keychain.loadCloudLLMKey() == nil)
    }
}
