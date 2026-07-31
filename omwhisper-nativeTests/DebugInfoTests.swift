import Testing
@testable import OmWhisper

@Suite("DebugInfo")
struct DebugInfoTests {
    // Taking the wrong end produces a dump that looks complete and is useless —
    // whatever went wrong is always in the last lines, not the first.
    @Test("keeps the newest lines, in order")
    func keepsNewest() {
        #expect(DebugInfo.newestLines(["a", "b", "c", "d"], limit: 2) == ["c", "d"])
    }

    @Test("returns everything when under the limit")
    func underLimit() {
        #expect(DebugInfo.newestLines(["a", "b"], limit: 10) == ["a", "b"])
    }

    @Test("empty stays empty")
    func empty() {
        #expect(DebugInfo.newestLines([], limit: 10).isEmpty)
    }
}
