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

    @Test("cloud can never be a long-form candidate")
    func noCloudCase() {
        // Recordings and chronicles must never egress. That is guaranteed by
        // Kind having no cloud case rather than by a check, so this asserts the
        // enum itself — it fails the moment someone adds one.
        #expect(LongFormBackends.Kind.allCases == [.ollama, .system])
    }
}
