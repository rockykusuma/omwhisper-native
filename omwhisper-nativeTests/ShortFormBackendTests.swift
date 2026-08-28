import Testing
@testable import OmWhisper

/// Mirrors LongFormBackends: the whole decision is pure, so "which backend does
/// this feature actually use" is answerable without constructing AppState.
struct ShortFormBackendTests {
    @Test func defaultResolvesThroughTheDefaultRow() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .useDefault,
                                         defaultChoice: .system, dictationPolishEnabled: true)
                == .system)
    }

    @Test func anExplicitChoiceWinsOverTheDefaultRow() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .cloud,
                                         defaultChoice: .system, dictationPolishEnabled: true)
                == .cloud)
    }

    /// The toggle governs dictation polish ONLY. Reply Assist has its own
    /// enable flag and must not be switched off by another feature's control —
    /// that coupling is the bug this whole change exists to remove.
    @Test func theToggleGovernsDictationPolishAlone() {
        #expect(ShortFormBackend.resolve(feature: .dictationPolish, choice: .system,
                                         defaultChoice: .useDefault, dictationPolishEnabled: false)
                == nil)
        #expect(ShortFormBackend.resolve(feature: .replyAssist, choice: .system,
                                         defaultChoice: .useDefault, dictationPolishEnabled: false)
                == .system)
    }

    /// Both left on Default means "no backend chosen", not a silent fallback to
    /// something. The caller treats nil as a configuration state, not a fault.
    @Test func defaultOnDefaultIsNoChoice() {
        #expect(ShortFormBackend.resolve(feature: .replyAssist, choice: .useDefault,
                                         defaultChoice: .useDefault, dictationPolishEnabled: true)
                == nil)
    }
}
