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
        #expect(WhisperModel.whisperKitModelID(for: .largeV3Turbo) == "openai_whisper-large-v3_947MB")
    }

    @Test("decodeLanguage maps auto to nil, else the code")
    func language() {
        #expect(WhisperModel.decodeLanguage("auto") == nil)
        #expect(WhisperModel.decodeLanguage("te") == "te")
        #expect(WhisperModel.decodeLanguage("en") == "en")
    }

    /// TranscriptionSegment.text (the only timestamped text WhisperKit exposes)
    /// arrives raw — these are real strings from a recorded meeting, which landed
    /// verbatim in the transcript before this stripped them.
    @Test("stripSpecialTokens removes <|...|> markers and tidies the gaps")
    func specialTokens() {
        #expect(WhisperModel.stripSpecialTokens(
            "<|startoftranscript|><|en|><|transcribe|><|0.00|> AI is coming<|3.44|>"
        ) == "AI is coming")
        // Two timestamped runs joined into one segment: no doubled spaces.
        #expect(WhisperModel.stripSpecialTokens(
            "<|3.44|> first part<|9.20|> <|9.20|> second part<|14.44|>"
        ) == "first part second part")
        #expect(WhisperModel.stripSpecialTokens("already clean") == "already clean")
        #expect(WhisperModel.stripSpecialTokens("<|nospeech|>") == "")
    }

    @Test("vocabularyPrompt joins terms; empty list yields empty string")
    func prompt() {
        #expect(WhisperModel.vocabularyPrompt([]) == "")
        #expect(WhisperModel.vocabularyPrompt(["SwiftUI", "Parakeet"]) == "SwiftUI, Parakeet")
    }
}
