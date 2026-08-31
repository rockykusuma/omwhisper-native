import Testing
@testable import OmWhisper

/// Every case here came from a review finding or from the behaviour of a build
/// that shipped a bug. The theme: resolution must never lose the model, never
/// invent cloud, and never speak for a feature that is switched off.
struct ShortFormBackendTests {
    private func r(_ feature: AIFeature = .dictationPolish,
                   choice: FeatureBackend = .useDefault,
                   def: FeatureBackend = .useDefault,
                   shared: String = "", system: Bool = true,
                   enabled: Bool = true) -> FeatureBackend? {
        ShortFormBackend.resolve(feature: feature, choice: choice, defaultChoice: def,
                                 sharedOllamaModel: shared, systemAvailable: system,
                                 dictationPolishEnabled: enabled)
    }

    /// The 2026-08-28 regression: this used to be nil, so switching polish on
    /// did nothing on a stock install and said nothing about it.
    @Test func defaultOnDefaultPicksAnOnDeviceBackend() {
        #expect(r() == .system)
        #expect(r(shared: "qwen3.5:latest", system: false) == .ollama(model: "qwen3.5:latest"))
        #expect(r(system: false) == nil)   // nothing usable is nil, not invented
    }

    /// The 2026-08-30 regression: a row set to Ollama · <model> was DISCARDED
    /// whenever the shared ollamaModel was empty, because resolution gated on
    /// the shared value instead of reading the row's own.
    @Test func anExplicitModelSurvivesAnEmptySharedSetting() {
        #expect(r(choice: .ollama(model: "qwen3.5:latest"), shared: "")
                == .ollama(model: "qwen3.5:latest"))
        #expect(r(def: .ollama(model: "qwen3.5:latest"), shared: "")
                == .ollama(model: "qwen3.5:latest"))
    }

    /// The Default row's model must win over the shared setting, or a different
    /// model runs than the one selected — and a 3B model is documented as making
    /// these features look broken.
    @Test func theChosenModelWinsOverTheSharedOne() {
        #expect(r(def: .ollama(model: "qwen3.5:latest"), shared: "llama3.2:3b")
                == .ollama(model: "qwen3.5:latest"))
    }

    @Test func anUnavailableSystemChoiceFallsBackOnDeviceNeverToCloud() {
        #expect(r(choice: .system, shared: "m", system: false) == .ollama(model: "m"))
        #expect(r(choice: .system, system: false) == nil)
    }

    @Test func cloudOnlyWhenChosen() {
        #expect(r() != .cloud)
        #expect(r(choice: .cloud) == .cloud)
        #expect(r(def: .cloud) == .cloud)
    }

    @Test func theToggleGovernsDictationPolishAlone() {
        #expect(r(.dictationPolish, enabled: false) == nil)
        #expect(r(.replyAssist, enabled: false) == .system)
    }

    /// wantsSystem must describe the CHOICE, not the outcome — otherwise the
    /// nudge fires for a feature nobody pointed at Apple Intelligence, and stays
    /// silent for one that was.
    @Test func wantsSystemDescribesTheChoiceNotTheFallback() {
        #expect(ShortFormBackend.wantsSystem(choice: .system, defaultChoice: .useDefault))
        #expect(ShortFormBackend.wantsSystem(choice: .useDefault, defaultChoice: .system))
        #expect(!ShortFormBackend.wantsSystem(choice: .useDefault, defaultChoice: .useDefault))
        #expect(!ShortFormBackend.wantsSystem(choice: .ollama(model: "m"), defaultChoice: .system))
    }

    /// Egress is resolver-independent: cloud is reachable only from an explicit
    /// choice on BOTH paths, so this answers correctly for meetings too.
    @Test func egressesIsTrueOnlyForAnExplicitCloudChoice() {
        #expect(ShortFormBackend.egresses(choice: .cloud, defaultChoice: .useDefault))
        #expect(ShortFormBackend.egresses(choice: .useDefault, defaultChoice: .cloud))
        #expect(!ShortFormBackend.egresses(choice: .system, defaultChoice: .cloud))
        #expect(!ShortFormBackend.egresses(choice: .useDefault, defaultChoice: .useDefault))
    }
}
