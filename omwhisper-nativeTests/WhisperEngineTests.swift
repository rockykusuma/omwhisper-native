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

    /// The bug this guards: Constants.languages is keyed by NAME and maps 112
    /// names onto 100 codes (dutch/flemish → nl), so ForEach(id: \.code) hit
    /// duplicate IDs — console spam, and undefined Picker selection.
    @Test("languageOptions has exactly one row per code")
    func languageOptionsAreUnique() {
        let codes = WhisperEngine.languageOptions.map(\.code)
        #expect(codes.count == Set(codes).count)
        #expect(!codes.isEmpty)
        // Every duplicated code from the real dict survives exactly once.
        for dup in ["nl", "ro", "zh", "es", "ca", "pa", "ps", "si", "lb", "ht", "my", "en"] {
            #expect(codes.filter { $0 == dup }.count == 1, "expected exactly one row for \(dup)")
        }
    }

    @Test("languageOptions are named and sorted, never blank")
    func languageOptionsAreNamed() {
        let opts = WhisperEngine.languageOptions
        #expect(opts.allSatisfy { !$0.name.isEmpty })
        #expect(opts.map(\.name) == opts.map(\.name).sorted())
    }

    /// Locale gives the canonical name; the old Dictionary.first lookup was
    /// UNORDERED, so "es" returned "Castilian" or "Spanish" at random.
    @Test("languageName resolves codes canonically, auto to empty")
    func languageNames() {
        #expect(WhisperEngine.languageName(forCode: "auto") == "")
        #expect(WhisperEngine.languageName(forCode: "es") == "Spanish")
        #expect(WhisperEngine.languageName(forCode: "ro") == "Romanian")
        #expect(WhisperEngine.languageName(forCode: "nl") == "Dutch")
        #expect(WhisperEngine.languageName(forCode: "te") == "Telugu")
        // Whisper ships codes Locale still resolves: yue, and the nonstandard jw.
        #expect(WhisperEngine.languageName(forCode: "yue") == "Cantonese")
        #expect(WhisperEngine.languageName(forCode: "jw") == "Javanese")
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

    /// Real outputs measured from this app's own models: base/small return
    /// "[BLANK_AUDIO]" for a silent recording and "[MUSIC PLAYING]" for a blip.
    /// WhisperKit never suppresses these (its nonSpeechTokens() is an
    /// unimplemented TODO), so without stripping they get pasted.
    @Test("stripNonSpeechAnnotations removes caption markup, keeps real words")
    func nonSpeechAnnotations() {
        #expect(WhisperModel.stripNonSpeechAnnotations("[BLANK_AUDIO]") == "")
        #expect(WhisperModel.stripNonSpeechAnnotations("[MUSIC PLAYING]") == "")
        #expect(WhisperModel.stripNonSpeechAnnotations("[INAUDIBLE]") == "")
        // Mid-transcript: a pause inside otherwise-real speech.
        #expect(WhisperModel.stripNonSpeechAnnotations(
            "so the plan is [BLANK_AUDIO] we ship on Friday"
        ) == "so the plan is we ship on Friday")
        // Parenthesised markup — "(bell rings)" came out of a real recording on
        // disk, which is why the paren arm exists at all.
        #expect(WhisperModel.stripNonSpeechAnnotations("(bell rings) (bell rings)") == "")
        #expect(WhisperModel.stripNonSpeechAnnotations("(upbeat music) hello") == "hello")
        // Ordinary speech must survive untouched — including brackets/parens that
        // aren't the annotation shape.
        #expect(WhisperModel.stripNonSpeechAnnotations("already clean") == "already clean")
        #expect(WhisperModel.stripNonSpeechAnnotations("the array[i] lookup") == "the array[i] lookup")
        #expect(WhisperModel.stripNonSpeechAnnotations("ship v2 (Q3) then") == "ship v2 (Q3) then")
        // Bounded: a long parenthetical is a real clause, not a sound effect.
        let clause = "the call (which we agreed would be recorded beforehand) went fine"
        #expect(WhisperModel.stripNonSpeechAnnotations(clause) == clause)
    }

    @Test("cleanTranscript strips tokens and annotations together")
    func cleanTranscript() {
        #expect(WhisperModel.cleanTranscript(
            "<|startoftranscript|><|en|><|0.00|> [BLANK_AUDIO]<|5.00|>"
        ) == "")
        #expect(WhisperModel.cleanTranscript(
            "<|0.00|> hello there [MUSIC PLAYING] friend<|3.44|>"
        ) == "hello there friend")
        #expect(WhisperModel.cleanTranscript("just words") == "just words")
    }
}
