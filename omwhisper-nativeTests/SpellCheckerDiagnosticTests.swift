import AppKit
import Testing
@testable import OmWhisper

// TEMPORARY DIAGNOSTIC — establishes why NSSpellChecker flags nothing on the CI
// runner. Two candidate causes, different fixes:
//   H1  the spell service isn't running at all      -> test-environment issue
//   H2  no spell-check language is configured       -> real product bug
// NSLog because that's what demonstrably reaches the CI log.
@Suite("SpellChecker diagnostic")
struct SpellCheckerDiagnosticTests {
    @Test @MainActor func diagnose() {
        let checker = NSSpellChecker.shared
        let language: String = checker.language()
        let available: [String] = checker.availableLanguages
        let preferred: [String] = checker.userPreferredLanguages
        let autoIdentifies: Bool = checker.automaticallyIdentifiesLanguages

        let auto: NSRange = checker.checkSpelling(of: "classe", startingAt: 0)
        var words = 0
        let explicit: NSRange = checker.checkSpelling(
            of: "classe", startingAt: 0, language: "en",
            wrap: false, inSpellDocumentWithTag: 0, wordCount: &words)
        let gibberish: NSRange = checker.checkSpelling(of: "zzqxwv", startingAt: 0)

        var lines: [String] = []
        lines.append("DIAG language=" + language)
        lines.append("DIAG available=" + available.joined(separator: ","))
        lines.append("DIAG preferred=" + preferred.joined(separator: ","))
        lines.append("DIAG autoIdentifies=" + String(autoIdentifies))
        lines.append("DIAG classe/auto loc=" + String(auto.location) + " len=" + String(auto.length))
        lines.append("DIAG classe/en loc=" + String(explicit.location) + " len=" + String(explicit.length))
        lines.append("DIAG zzqxwv/auto loc=" + String(gibberish.location) + " len=" + String(gibberish.length))
        NSLog("%@", lines.joined(separator: "\n"))
    }
}
