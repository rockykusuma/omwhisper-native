import Testing
@testable import OmWhisper

/// Short-form shares LongFormBackends' rule and supplies its own on-device
/// order. The tests that matter are the ones that would have caught the
/// 2026-08-28 regression: Default-on-Default must be an order, never nothing.
struct ShortFormBackendTests {
    private func c(_ feature: AIFeature = .dictationPolish,
                   choice: FeatureBackend = .useDefault,
                   def: FeatureBackend = .useDefault,
                   ollama: Bool = true, system: Bool = true, cloud: Bool = true,
                   enabled: Bool = true) -> [LongFormBackends.Kind] {
        ShortFormBackend.candidates(feature: feature, choice: choice, defaultChoice: def,
                                    ollamaConfigured: ollama, systemAvailable: system,
                                    cloudConfigured: cloud, dictationPolishEnabled: enabled)
    }

    /// The regression that shipped: this used to be empty, so switching polish
    /// on did nothing on a stock install and said nothing about it.
    @Test func defaultOnDefaultIsTheOnDeviceOrderNotNothing() {
        #expect(c() == [.system, .ollama])
    }

    /// Dictation is latency-bound, so Apple Intelligence comes first — the
    /// exact opposite of the long-form order, for a measured reason.
    @Test func shortFormPrefersSystemWhereLongFormPrefersOllama() {
        #expect(c() == [.system, .ollama])
        #expect(LongFormBackends.candidates(choice: .useDefault, defaultChoice: .useDefault,
                                            ollamaConfigured: true, systemAvailable: true,
                                            cloudConfigured: true) == [.ollama, .system])
    }

    @Test func anExplicitChoiceLeadsAndOnDeviceStillFollows() {
        #expect(c(choice: .ollama(model: "m")) == [.ollama, .system])
        #expect(c(def: .system) == [.system, .ollama])
    }

    /// Cloud is never a fallback — only ever first, and only when chosen.
    @Test func cloudAppearsOnlyWhenChosen() {
        #expect(c() .contains(.cloud) == false)
        #expect(c(choice: .cloud) == [.cloud, .system, .ollama])
        #expect(c(choice: .cloud, cloud: false) == [.system, .ollama])
    }

    @Test func theToggleGovernsDictationPolishAlone() {
        #expect(c(.dictationPolish, enabled: false).isEmpty)
        #expect(c(.replyAssist, enabled: false) == [.system, .ollama])
    }

    /// Nothing usable is empty, not an invented fallback.
    @Test func nothingAvailableIsEmpty() {
        #expect(c(ollama: false, system: false).isEmpty)
    }
}
