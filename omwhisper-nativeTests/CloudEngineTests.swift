import Testing
import Foundation
@testable import OmWhisper

@Suite("CloudEngine")
struct CloudEngineTests {
    @Test("keeps vocabulary under the 100-term cap")
    func capsTermCount() {
        let vocabulary = (1...150).map { "term\($0)" }
        #expect(CloudEngine.cappedKeyterms(vocabulary).count == 100)
    }

    @Test("truncates a term longer than 50 characters")
    func truncatesLongTerm() {
        let longTerm = String(repeating: "a", count: 80)
        let result = CloudEngine.cappedKeyterms([longTerm])
        #expect(result == [String(repeating: "a", count: 50)])
    }

    @Test("passes short terms through unchanged")
    func passesShortTermsThrough() {
        #expect(CloudEngine.cappedKeyterms(["OmWhisper", "Parakeet"]) == ["OmWhisper", "Parakeet"])
    }

    @Test("empty vocabulary produces an empty list")
    func emptyVocabulary() {
        #expect(CloudEngine.cappedKeyterms([]) == [])
    }

    @Test("connection URL carries sample_rate, encoding, and the required speech_model/mode")
    func connectionURLBaseParams() {
        let url = CloudEngine.connectionURL(keyterms: [])
        let query = url.query ?? ""
        #expect(url.absoluteString.hasPrefix("wss://streaming.assemblyai.com/v3/ws?"))
        #expect(query.contains("sample_rate=16000"))
        #expect(query.contains("encoding=pcm_s16le"))
        #expect(query.contains("speech_model=universal-3-5-pro"))
        #expect(query.contains("mode=balanced"))
        #expect(!query.contains("keyterms_prompt"))
    }

    @Test("connection URL includes keyterms_prompt as a JSON array when non-empty")
    func connectionURLWithKeyterms() {
        let url = CloudEngine.connectionURL(keyterms: ["OmWhisper", "Parakeet"])
        let query = url.query ?? ""
        #expect(query.contains("keyterms_prompt="))
        #expect(query.contains("OmWhisper"))
        #expect(query.contains("Parakeet"))
    }

    @Test("a Turn message with end_of_turn true maps to .final")
    func finalTurnMapsToFinal() {
        let json = """
        {"type": "Turn", "end_of_turn": true, "transcript": "hello world"}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == .final("hello world"))
    }

    @Test("a Turn message with end_of_turn false maps to .partial")
    func partialTurnMapsToPartial() {
        let json = """
        {"type": "Turn", "end_of_turn": false, "transcript": "hello wor"}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == .partial("hello wor"))
    }

    @Test("a Begin message produces no event")
    func beginMessageProducesNoEvent() {
        let json = """
        {"type": "Begin", "id": "abc-123", "expires_at": 1234567890}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }

    @Test("a Termination message produces no event")
    func terminationMessageProducesNoEvent() {
        let json = """
        {"type": "Termination", "audio_duration_seconds": 12, "session_duration_seconds": 13}
        """
        let data = Data(json.utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }

    @Test("malformed JSON produces no event")
    func malformedJSONProducesNoEvent() {
        let data = Data("not json".utf8)
        #expect(CloudEngine.parseServerMessage(data) == nil)
    }

    @Test("CloudProviderKind rawValues round-trip and Keychain accounts are unique")
    func providerKinds() {
        #expect(CloudProviderKind(rawValue: "deepgram") == .deepgram)
        #expect(CloudProviderKind.allCases.count == 5)
        let accounts = Set(CloudProviderKind.allCases.map(\.keychainAccount))
        #expect(accounts.count == 5)   // no account collisions across providers
        #expect(CloudProviderKind.assemblyAI.keychainAccount == "assemblyai-api-key")  // M4.2 back-compat
        #expect(CloudProviderKind.assemblyAI.isStreaming)
        #expect(!CloudProviderKind.groq.isStreaming)
    }
}
