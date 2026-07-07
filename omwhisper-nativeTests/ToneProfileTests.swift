import Testing
import Foundation
@testable import OmWhisper

@Suite("ToneProfile")
struct ToneProfileTests {
    private func entry(_ text: String) -> TranscriptionEntry {
        TranscriptionEntry(
            id: nil, text: text, durationSeconds: 1, modelUsed: "test",
            createdAt: "2026-07-08T00:00:00Z", wordCount: text.split(separator: " ").count,
            source: "raw", rawText: nil, polishStyle: nil
        )
    }

    @Test("buildDigest concatenates entry text with newlines")
    func digestConcatenates() {
        let digest = ToneProfile.buildDigest(from: [entry("hello there"), entry("how are you")])
        #expect(digest == "hello there\nhow are you\n")
    }

    @Test("buildDigest caps at sampleCap entries")
    func digestCapsSampleCount() {
        let entries = (0..<(ToneProfile.sampleCap + 20)).map { entry("entry \($0)") }
        let digest = ToneProfile.buildDigest(from: entries)
        let lineCount = digest.split(separator: "\n").count
        #expect(lineCount == ToneProfile.sampleCap)
    }

    @Test("buildDigest stops before exceeding digestCharCap")
    func digestCapsCharCount() {
        let longEntry = entry(String(repeating: "x", count: ToneProfile.digestCharCap))
        let digest = ToneProfile.buildDigest(from: [longEntry, entry("short")])
        #expect(digest.count <= ToneProfile.digestCharCap + 1)  // +1 for the trailing newline of the entry that fit
        #expect(!digest.contains("short"))
    }

    @Test("buildDigest on an empty entry list returns an empty digest")
    func emptyEntries() {
        #expect(ToneProfile.buildDigest(from: []) == "")
    }

    @Test("promptPrefix truncates to promptPrefixCap")
    func prefixTruncates() {
        let long = String(repeating: "a", count: ToneProfile.promptPrefixCap + 500)
        #expect(ToneProfile.promptPrefix(from: long).count == ToneProfile.promptPrefixCap)
    }

    @Test("promptPrefix passes short tone files through unchanged")
    func prefixPassesThroughShort() {
        #expect(ToneProfile.promptPrefix(from: "short tone") == "short tone")
    }
}
