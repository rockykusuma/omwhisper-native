import Testing
import Foundation
@testable import OmWhisper

@Suite("CrossLingual")
struct CrossLingualTests {
    // A stand-in for the built-in Professional style.
    private var professional: PolishStyle {
        PolishStyle(id: UUID(uuidString: "8A5C1E10-0001-4C1A-9C1E-000000000001")!,
                    name: "Professional", prompt: "Rewrite in a formal, polished tone.", isBuiltIn: true)
    }
    // The built-in Translate style (same fixed UUID as PolishStyles).
    private var translate: PolishStyle {
        PolishStyle(id: CrossLingual.translateStyleID,
                    name: "Translate", prompt: "Translate into {language}.", isBuiltIn: true,
                    requiresTargetLanguage: true)
    }

    @Test func forcesWhisperWhenOn() {
        #expect(CrossLingual.engineKind(base: .apple, crossLingual: true) == .whisper)
        #expect(CrossLingual.engineKind(base: .cloud, crossLingual: true) == .whisper)
    }

    @Test func passesThroughWhenOff() {
        #expect(CrossLingual.engineKind(base: .apple, crossLingual: false) == .apple)
        #expect(CrossLingual.engineKind(base: .parakeet, crossLingual: false) == .parakeet)
    }

    @Test func inEngineTranslateOnlyWhenNoBackend() {
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: true, hasBackend: false) == true)
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: true, hasBackend: true) == false)
        #expect(CrossLingual.whisperTranslatesInEngine(crossLingual: false, hasBackend: false) == false)
    }

    @Test func promptNamesLanguageAndFoldsActiveStyle() {
        let p = CrossLingual.style(spokenLanguage: "Telugu", activeStyle: professional).prompt
        #expect(p.contains("Telugu"))
        #expect(p.contains("Translate and normalize"))
        #expect(p.contains("formal, polished tone"))   // active style folded in
        #expect(p.hasSuffix("Output only the English text, nothing else."))
    }

    @Test func translateStyleIsSupersededNotAppended() {
        let p = CrossLingual.style(spokenLanguage: "Hindi", activeStyle: translate).prompt
        #expect(!p.contains("Additionally, follow this style instruction"))
        #expect(!p.contains("{language}"))
    }

    @Test func autoAndNilStyleGiveNeutralPrompt() {
        let p = CrossLingual.style(spokenLanguage: "auto", activeStyle: nil).prompt
        #expect(p.contains("another language"))
        #expect(!p.contains("Additionally, follow this style instruction"))
    }
}
