import Testing
@testable import OmWhisper

/// `polishBackend` governed exactly two features: dictation polish and Reply
/// Assist. Migrating it anywhere else changes where data goes without anything
/// appearing on screen. Every case below came from a real review finding or the
/// behaviour of the build being upgraded FROM.
struct PolishBackendMigrationTests {
    private func plan(_ old: String?, dictation: FeatureBackend = .useDefault,
                      reply: FeatureBackend = .useDefault,
                      ollamaModel: String = "",
                      defaultIsCloud: Bool = false) -> PolishBackendMigration.Plan {
        PolishBackendMigration.plan(old: old, existingDictation: dictation,
                                    existingReplyAssist: reply, ollamaModel: ollamaModel,
                                    defaultIsCloud: defaultIsCloud)
    }

    @Test func absentKeyChangesNothing() {
        let p = plan(nil)
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
        #expect(p.replyAssistEnabled == nil)
    }

    /// On the old build, activePolishBackend switched on the per-feature choice
    /// FIRST. Someone with an explicit choice and no global had WORKING polish;
    /// keying the toggle off the global alone switched it off, silently.
    @Test func anExplicitChoiceMeansPolishWasWorkingAndStaysOn() {
        #expect(plan(nil, dictation: .system).dictationPolishEnabled)
        #expect(plan("disabled", dictation: .system).dictationPolishEnabled)
        // ...and the slot it already had is never rewritten.
        #expect(plan(nil, dictation: .system).dictationBackend == nil)
    }

    @Test func systemMigratesToBothShortFormFeatures() {
        let p = plan("system")
        #expect(p.dictationPolishEnabled)
        #expect(p.dictationBackend == .system)
        #expect(p.replyAssistBackend == .system)
    }

    /// Rule 1: an upgrade may make things MORE private, never less. Writing the
    /// old cloud choice into slots the user never set is data leaving the Mac
    /// because of a refactor.
    @Test func cloudIsNeverWrittenByAMigration() {
        let p = plan("cloud")
        #expect(p.dictationBackend == nil, "a migration produced cloud")
        #expect(p.replyAssistBackend == nil, "a migration produced cloud")
        #expect(p.dictationPolishEnabled, "polish was on before and should stay on, just on-device")
    }

    @Test func ollamaCarriesTheModelAcross() {
        let p = plan("ollama", ollamaModel: "qwen3.5:latest")
        #expect(p.dictationBackend == .ollama(model: "qwen3.5:latest"))
        #expect(p.replyAssistBackend == .ollama(model: "qwen3.5:latest"))
    }

    /// `.ollama(model: "")` encodes as "ollama:", which FeatureBackend rejects
    /// on read-back — the slot would silently become Default and resolve through
    /// the Default row, cloud included. It produced no polish before, either.
    @Test func ollamaWithNoModelWritesNothing() {
        let p = plan("ollama", ollamaModel: "")
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
        #expect(p.dictationPolishEnabled == false)
    }

    /// "Disabled" meant no AI for BOTH short-form features. Reply Assist has no
    /// backend value for that, and Default now resolves through the Default row,
    /// so its own switch has to carry the meaning across.
    /// Reply Assist is switched off ONLY where leaving it on Default would now
    /// egress. Doing it unconditionally was a regression: on a stock install the
    /// Default row resolves on-device, so it gained no privacy and silently
    /// killed a feature the user had enabled.
    @Test func disabledProtectsReplyAssistOnlyWhenDefaultWouldEgress() {
        #expect(plan("disabled", defaultIsCloud: true).replyAssistEnabled == false)
        #expect(plan("disabled", defaultIsCloud: false).replyAssistEnabled == nil,
                "Reply Assist was disabled for no privacy gain")
        #expect(plan("disabled").dictationPolishEnabled == false)
        // An explicit Reply Assist choice was already working — leave it alone.
        #expect(plan("disabled", reply: .system, defaultIsCloud: true).replyAssistEnabled == nil)
    }

    @Test func anExplicitPerFeatureChoiceIsNeverOverwritten() {
        let p = plan("system", dictation: .ollama(model: "m"))
        #expect(p.dictationBackend == nil, "an explicit choice was overwritten")
        #expect(p.replyAssistBackend == .system)
    }

    @Test func anUnrecognisedValueIsTreatedAsNothingToDo() {
        let p = plan("gibberish")
        #expect(p.dictationPolishEnabled == false)
        #expect(p.dictationBackend == nil)
        #expect(p.replyAssistBackend == nil)
    }

    /// The load-bearing rule, enforced by the TYPE: Plan has no field for the
    /// global or for any long-form feature, so the privacy regression is
    /// unrepresentable. Pinned so adding one turns a test red.
    @Test func planCannotNameTheGlobalOrALongFormFeature() {
        let fields = Mirror(reflecting: PolishBackendMigration.Plan(
            dictationPolishEnabled: false, dictationBackend: nil,
            replyAssistBackend: nil, replyAssistEnabled: nil
        )).children.compactMap(\.label).sorted()
        #expect(fields == ["dictationBackend", "dictationPolishEnabled",
                           "replyAssistBackend", "replyAssistEnabled"])
    }
}
