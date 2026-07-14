import Testing
import Foundation
@testable import OmWhisper

@Suite("CloudEngine")
struct CloudEngineTests {
    @Test("keeps vocabulary under the 100-term cap")
    func capsTermCount() {
        let vocabulary = (1...150).map { "term\($0)" }
        #expect(AssemblyAIProvider.cappedKeyterms(vocabulary).count == 100)
    }

    @Test func sarvamConfigShape() {
        let c = BatchCloudTranscriber.sarvam()
        #expect(c.url.absoluteString == "https://api.sarvam.ai/speech-to-text")
        #expect(c.authHeader == "api-subscription-key")
        #expect(c.authBearer == false)
        #expect(c.model == "saaras:v3")
        #expect(c.extraFields["mode"] == "translate")
        #expect(c.responseKey == "transcript")
    }

    @Test func multipartEmitsExtraFields() {
        let wav = BatchCloudTranscriber.pcmToWav(int16: [0, 0, 0], sampleRate: 16000)
        let body = BatchCloudTranscriber.multipartBody(
            wav: wav, config: BatchCloudTranscriber.sarvam(), language: nil, boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        #expect(s.contains("name=\"model\""))
        #expect(s.contains("saaras:v3"))
        #expect(s.contains("name=\"mode\""))
        #expect(s.contains("translate"))
    }

    @Test("truncates a term longer than 50 characters")
    func truncatesLongTerm() {
        let longTerm = String(repeating: "a", count: 80)
        let result = AssemblyAIProvider.cappedKeyterms([longTerm])
        #expect(result == [String(repeating: "a", count: 50)])
    }

    @Test("passes short terms through unchanged")
    func passesShortTermsThrough() {
        #expect(AssemblyAIProvider.cappedKeyterms(["OmWhisper", "Parakeet"]) == ["OmWhisper", "Parakeet"])
    }

    @Test("empty vocabulary produces an empty list")
    func emptyVocabulary() {
        #expect(AssemblyAIProvider.cappedKeyterms([]) == [])
    }

    @Test("connection URL carries sample_rate, encoding, and the required speech_model/mode")
    func connectionURLBaseParams() {
        let url = AssemblyAIProvider.connectionURL(keyterms: [])
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
        let url = AssemblyAIProvider.connectionURL(keyterms: ["OmWhisper", "Parakeet"])
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
        #expect(AssemblyAIProvider.parseServerMessage(data) == .final("hello world"))
    }

    @Test("a Turn message with end_of_turn false maps to .partial")
    func partialTurnMapsToPartial() {
        let json = """
        {"type": "Turn", "end_of_turn": false, "transcript": "hello wor"}
        """
        let data = Data(json.utf8)
        #expect(AssemblyAIProvider.parseServerMessage(data) == .partial("hello wor"))
    }

    @Test("a Begin message produces no event")
    func beginMessageProducesNoEvent() {
        let json = """
        {"type": "Begin", "id": "abc-123", "expires_at": 1234567890}
        """
        let data = Data(json.utf8)
        #expect(AssemblyAIProvider.parseServerMessage(data) == nil)
    }

    @Test("a Termination message produces no event")
    func terminationMessageProducesNoEvent() {
        let json = """
        {"type": "Termination", "audio_duration_seconds": 12, "session_duration_seconds": 13}
        """
        let data = Data(json.utf8)
        #expect(AssemblyAIProvider.parseServerMessage(data) == nil)
    }

    @Test("malformed JSON produces no event")
    func malformedJSONProducesNoEvent() {
        let data = Data("not json".utf8)
        #expect(AssemblyAIProvider.parseServerMessage(data) == nil)
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

    // MARK: Batch transcriber

    @Test("pcmToWav emits a valid 44-byte WAV header + payload")
    func wavHeader() {
        let wav = BatchCloudTranscriber.pcmToWav(int16: [1, -1, 100], sampleRate: 16000)
        #expect(wav.count == 44 + 3 * 2)                       // header + 3 samples
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8..<12] == Data("WAVE".utf8))
        #expect(wav[36..<40] == Data("data".utf8))
    }

    @Test("multipartBody carries model field, language, and the file part")
    func multipart() {
        let cfg = BatchCloudTranscriber.groq()
        let body = BatchCloudTranscriber.multipartBody(wav: Data([0, 0]), config: cfg, language: "te", boundary: "B")
        let s = String(decoding: body, as: UTF8.self)
        #expect(s.contains("name=\"model\"") && s.contains("whisper-large-v3-turbo"))
        #expect(s.contains("name=\"language\"") && s.contains("te"))
        #expect(s.contains("filename=\"audio.wav\""))
        #expect(s.hasSuffix("--B--\r\n"))
    }

    @Test("multipartBody omits language when auto")
    func multipartAutoLanguage() {
        let cfg = BatchCloudTranscriber.openAI()
        let body = BatchCloudTranscriber.multipartBody(wav: Data(), config: cfg, language: "auto", boundary: "B")
        #expect(!String(decoding: body, as: UTF8.self).contains("name=\"language\""))
    }

    @Test("parseText extracts the response text field")
    func parseText() {
        let data = Data(#"{"text":"  hello world  ","language_code":"en"}"#.utf8)
        #expect(BatchCloudTranscriber.parseText(data, key: "text") == "hello world")
        #expect(BatchCloudTranscriber.parseText(Data("nope".utf8), key: "text") == nil)
    }

    @Test("config(for:) picks the batch providers and skips the streaming ones")
    func batchConfig() {
        #expect(BatchCloudTranscriber.config(for: .openAI)?.model == "gpt-4o-transcribe")
        #expect(BatchCloudTranscriber.config(for: .elevenLabs)?.modelField == "model_id")
        #expect(BatchCloudTranscriber.config(for: .elevenLabs)?.authHeader == "xi-api-key")
        #expect(BatchCloudTranscriber.config(for: .assemblyAI) == nil)
        #expect(BatchCloudTranscriber.config(for: .deepgram) == nil)
    }

    // MARK: Deepgram

    @Test("Deepgram connectionURL has the right host/params; omits language when auto")
    func deepgramURL() {
        let url = DeepgramProvider.connectionURL(language: "auto")
        #expect(url.host == "api.deepgram.com" && url.path == "/v1/listen")
        let q = url.query ?? ""
        #expect(q.contains("model=nova-3") && q.contains("encoding=linear16") && q.contains("sample_rate=16000"))
        #expect(!q.contains("language="))
        #expect(DeepgramProvider.connectionURL(language: "te").query?.contains("language=te") == true)
    }

    @Test("Deepgram parseResult maps is_final and skips empty/malformed")
    func deepgramParse() {
        let final = Data(#"{"channel":{"alternatives":[{"transcript":"hello"}]},"is_final":true}"#.utf8)
        #expect(DeepgramProvider.parseResult(final) == .final("hello"))
        let partial = Data(#"{"channel":{"alternatives":[{"transcript":"hel"}]},"is_final":false}"#.utf8)
        #expect(DeepgramProvider.parseResult(partial) == .partial("hel"))
        let empty = Data(#"{"channel":{"alternatives":[{"transcript":""}]},"is_final":true}"#.utf8)
        #expect(DeepgramProvider.parseResult(empty) == nil)
        #expect(DeepgramProvider.parseResult(Data("nope".utf8)) == nil)
    }
}
