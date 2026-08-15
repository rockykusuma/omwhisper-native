import Testing
@testable import OmWhisper

@Suite("Long-form backend preference")
struct LongFormBackendsTests {
    @Test("Ollama comes first when both are usable")
    func ollamaPreferredOverSystem() {
        // The whole point of the change. A test that only checked "the list is
        // non-empty" would pass with the order reversed, which is the bug.
        #expect(LongFormBackends.order(ollamaConfigured: true, systemAvailable: true)
                == [.ollama, .system])
    }

    @Test("each backend alone is used alone")
    func singleCandidates() {
        #expect(LongFormBackends.order(ollamaConfigured: true, systemAvailable: false) == [.ollama])
        #expect(LongFormBackends.order(ollamaConfigured: false, systemAvailable: true) == [.system])
    }

    @Test("neither available yields no candidates")
    func noCandidates() {
        // Callers distinguish "no backend at all" from "every backend failed",
        // so an empty list must stay empty rather than defaulting to something.
        #expect(LongFormBackends.order(ollamaConfigured: false, systemAvailable: false).isEmpty)
    }

    @Test("the display name names the model, not just the backend")
    func displayNameIncludesModel() {
        // "Ollama" alone does not distinguish a 3B model from a 9B one, and that
        // distinction is the entire reason a summary might read badly.
        #expect(LongFormBackends.displayName(for: .ollama, ollamaModel: "qwen3.5:latest")
                == "Ollama (qwen3.5:latest)")
        #expect(LongFormBackends.displayName(for: .system, ollamaModel: "qwen3.5:latest")
                == "Apple Intelligence")
        // An empty model should never render as "Ollama ()".
        #expect(LongFormBackends.displayName(for: .ollama, ollamaModel: "") == "Ollama")
    }

    @Test("cloud is a candidate ONLY when explicitly chosen")
    func cloudOnlyWhenChosen() {
        // Replaces the old `Kind.allCases == [.ollama, .system]` guard. That
        // test existed to stop this change being made carelessly; this one
        // pins what replaced it. Cloud must never appear for a feature that
        // did not ask for it, however unavailable everything else is.
        let everythingOff = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: false, cloudConfigured: true)
        #expect(everythingOff.isEmpty, "cloud leaked in as a last resort")

        let chosen = LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(chosen.first == .cloud)
    }

    @Test("an on-device choice never falls back to cloud")
    func onDeviceNeverFallsBackToCloud() {
        // THE rule. A fallback that reached for cloud when Ollama was down
        // would look like resilience and be a privacy breach.
        for choice in [FeatureBackend.system, .ollama(model: "qwen3.5")] {
            let list = LongFormBackends.candidates(
                choice: choice, defaultChoice: .useDefault,
                ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
            #expect(!list.contains(.cloud), "\(choice) offered cloud as a fallback")
        }
    }

    @Test("a cloud choice may fall back to on-device")
    func cloudMayFallBackLocally() {
        // The reverse direction is fine: less capable, never less private.
        let list = LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(list == [.cloud, .ollama, .system])
    }

    @Test("useDefault defers to the Default row")
    func useDefaultDefers() {
        let list = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .cloud,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: true)
        #expect(list.first == .cloud, "the Default row was ignored")
    }

    @Test("Default set to Default means today's automatic order")
    func defaultOfDefaultIsAutomatic() {
        // Shipping behaviour: nothing configured, everything on-device,
        // Ollama preferred for its larger envelope.
        let list = LongFormBackends.candidates(
            choice: .useDefault, defaultChoice: .useDefault,
            ollamaConfigured: true, systemAvailable: true, cloudConfigured: false)
        #expect(list == [.ollama, .system])
    }

    @Test("an unconfigured backend is skipped, not offered")
    func unconfiguredIsSkipped() {
        #expect(LongFormBackends.candidates(
            choice: .cloud, defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: false, cloudConfigured: false).isEmpty)
        #expect(LongFormBackends.candidates(
            choice: .ollama(model: "x"), defaultChoice: .useDefault,
            ollamaConfigured: false, systemAvailable: true, cloudConfigured: false) == [.system])
    }
}
