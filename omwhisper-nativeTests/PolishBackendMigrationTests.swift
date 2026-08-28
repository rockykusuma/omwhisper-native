import Testing
@testable import OmWhisper

/// `polishBackend` governed exactly two features: dictation polish and Reply
/// Assist, when those were left on Default. Migrating it anywhere else changes
/// where data goes without anything appearing on screen.
struct PolishBackendMigrationTests {
    @Test func absentKeyChangesNothing() {
        let p = PolishBackendMigration.plan(old: nil, existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }

    @Test func disabledTurnsTheFeatureOffAndTouchesNoBackend() {
        let p = PolishBackendMigration.plan(old: "disabled", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }

    @Test func systemMigratesToBothShortFormFeatures() {
        let p = PolishBackendMigration.plan(old: "system", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled)
        #expect(p.dictationBackend == .system)
        #expect(p.replyAssistBackend == .system)
    }

    @Test func cloudMigratesToBothShortFormFeatures() {
        let p = PolishBackendMigration.plan(old: "cloud", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationBackend == .cloud)
        #expect(p.replyAssistBackend == .cloud)
    }

    /// The old global stored only the KIND; the model lived in `ollamaModel`.
    /// Dropping it would migrate to an Ollama backend with no model, which
    /// resolves to nil and silently stops polishing.
    @Test func ollamaCarriesTheModelAcross() {
        let p = PolishBackendMigration.plan(old: "ollama", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault,
                                            ollamaModel: "qwen3.5:latest")
        #expect(p.dictationBackend == .ollama(model: "qwen3.5:latest"))
        #expect(p.replyAssistBackend == .ollama(model: "qwen3.5:latest"))
    }

    @Test func anExplicitPerFeatureChoiceIsNeverOverwritten() {
        let p = PolishBackendMigration.plan(old: "cloud", existingDictation: .system,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationBackend == nil, "an explicit choice was overwritten")
        #expect(p.replyAssistBackend == .cloud)
    }

    /// The load-bearing rule, enforced by the TYPE: Plan has no field for the
    /// global or for any long-form feature, so the privacy regression is
    /// unrepresentable. This pins the field set so adding one is a deliberate
    /// act that turns a test red rather than a quiet change.
    @Test func planCannotNameTheGlobalOrALongFormFeature() {
        let fields = Mirror(reflecting: PolishBackendMigration.Plan(
            dictationPolishEnabled: false, dictationBackend: nil, replyAssistBackend: nil
        )).children.compactMap(\.label).sorted()
        #expect(fields == ["dictationBackend", "dictationPolishEnabled", "replyAssistBackend"])
    }

    /// A value we do not recognise must not enable a feature that was off.
    @Test func anUnrecognisedValueIsTreatedAsNothingToDo() {
        let p = PolishBackendMigration.plan(old: "gibberish", existingDictation: .useDefault,
                                            existingReplyAssist: .useDefault, ollamaModel: "")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }
}
