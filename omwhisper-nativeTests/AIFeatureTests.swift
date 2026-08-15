import Foundation
import Testing
@testable import OmWhisper

@Suite("Per-feature backend choice")
struct AIFeatureTests {
    @Test("every feature has a stable settings key and a display name")
    func featuresAreComplete() {
        // Keys are PERSISTED. Renaming one silently resets that feature to
        // Default on the next launch, which for a cloud-enabled feature would
        // read as the setting being forgotten.
        #expect(AIFeature.allCases.count == 5)
        for f in AIFeature.allCases {
            #expect(!f.displayName.isEmpty)
            #expect(f.settingsKey.hasPrefix("aiBackend."))
        }
        #expect(Set(AIFeature.allCases.map(\.settingsKey)).count == AIFeature.allCases.count)
    }

    @Test("choices round-trip through their stored string")
    func choicesRoundTrip() {
        let all: [FeatureBackend] = [
            .useDefault, .system, .cloud,
            .ollama(model: "qwen3.5:latest"), .ollama(model: "gemma4"),
        ]
        for choice in all {
            #expect(FeatureBackend(rawValue: choice.rawValue) == choice,
                    "\(choice) did not survive a round trip")
        }
    }

    @Test("an unknown or corrupt stored value falls back to Default")
    func unknownValuesFallBackToDefault() {
        // The half that matters: a stored value from a future version, or a
        // typo, must not resolve to something arbitrary — and above all must
        // never resolve to cloud.
        #expect(FeatureBackend(rawValue: "") == nil)
        #expect(FeatureBackend(rawValue: "gibberish") == nil)
        #expect(FeatureBackend(rawValue: "ollama:") == nil)
    }

    @Test("an Ollama model containing a colon survives")
    func ollamaModelWithColon() {
        // Real model names are "qwen3.5:latest" — splitting on the first colon
        // only is load-bearing, and a naive split would store "qwen3.5" and
        // quietly select a model the user does not have.
        let choice = FeatureBackend.ollama(model: "qwen3.5:latest")
        #expect(choice.rawValue == "ollama:qwen3.5:latest")
        #expect(FeatureBackend(rawValue: "ollama:qwen3.5:latest") == choice)
    }
}
