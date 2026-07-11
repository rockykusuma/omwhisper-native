import Testing
@testable import OmWhisper

@Suite("WhisperEngine")
struct WhisperEngineTests {
    @Test("WhisperModel rawValues round-trip and cover all variants")
    func modelRawValues() {
        #expect(WhisperModel(rawValue: "base") == .base)
        #expect(WhisperModel(rawValue: "small") == .small)
        #expect(WhisperModel(rawValue: "largeV3Turbo") == .largeV3Turbo)
        #expect(WhisperModel.allCases == [.base, .small, .largeV3Turbo])
        #expect(WhisperModel(rawValue: "bogus") == nil)
    }

    @Test("model maps to the exact WhisperKit variant string")
    func modelID() {
        #expect(WhisperModel.whisperKitModelID(for: .base) == "openai_whisper-base")
        #expect(WhisperModel.whisperKitModelID(for: .small) == "openai_whisper-small")
        #expect(WhisperModel.whisperKitModelID(for: .largeV3Turbo) == "openai_whisper-large-v3-v20240930_turbo")
    }

    @Test("decodeLanguage maps auto to nil, else the code")
    func language() {
        #expect(WhisperModel.decodeLanguage("auto") == nil)
        #expect(WhisperModel.decodeLanguage("te") == "te")
        #expect(WhisperModel.decodeLanguage("en") == "en")
    }

    @Test("vocabularyPrompt joins terms; empty list yields empty string")
    func prompt() {
        #expect(WhisperModel.vocabularyPrompt([]) == "")
        #expect(WhisperModel.vocabularyPrompt(["SwiftUI", "Parakeet"]) == "SwiftUI, Parakeet")
    }
}
