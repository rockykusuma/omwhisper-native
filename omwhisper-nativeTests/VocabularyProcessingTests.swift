//
//  VocabularyProcessingTests.swift
//  omwhisper-nativeTests
//
//  Ports the Tauri app's engine.rs/vocab_correct.rs test suite 1:1 so the two
//  implementations stay easy to diff against each other.
//

import Testing
@testable import OmWhisper

struct ReplacementTests {
    @Test func emptyRulesReturnsTextUnchanged() {
        #expect(applyReplacements("hello world", rules: []) == "hello world")
    }

    @Test func simpleWholeWordReplacement() {
        let rules = [ReplacementRule(from: "okay", to: "OK")]
        #expect(applyReplacements("That is okay with me", rules: rules) == "That is OK with me")
    }

    @Test func partialWordNotReplaced() {
        let rules = [ReplacementRule(from: "ok", to: "OK")]
        #expect(applyReplacements("That is okay with me", rules: rules) == "That is okay with me")
    }

    @Test func replacementIsCaseInsensitive() {
        let rules = [ReplacementRule(from: "hello", to: "Hi")]
        #expect(applyReplacements("HELLO there", rules: rules) == "Hi there")
    }

    @Test func internalSpecialCharsEscaped() {
        let rules = [ReplacementRule(from: "v1.0", to: "version one")]
        #expect(applyReplacements("Running v1.0 now", rules: rules) == "Running version one now")
    }

    @Test func appliesRegardlessOfWhichEngineProducedTheText() {
        // Pure string -> string function — no engine-specific type involved.
        let rules = [ReplacementRule(from: "gonna", to: "going to")]
        #expect(applyReplacements("I'm gonna go", rules: rules) == "I'm going to go")
    }

    @Test func emptyFromRuleIsSkipped() {
        // \b\b would otherwise match every zero-width boundary and corrupt the string.
        let rules = [ReplacementRule(from: "", to: "X")]
        #expect(applyReplacements("hello world", rules: rules) == "hello world")
    }
}

struct FuzzyCorrectTests {
    let dict = ["Kubernetes", "Parakeet", "OmWhisper"]

    @Test func emptyDictIsNoop() {
        #expect(fuzzyCorrect("kubernetis cluster", dictionary: []) == "kubernetis cluster")
    }

    @Test func nearMissSnapsToTerm() {
        // "kubernetis" -> "Kubernetes" (distance 2, len >= 7 allows 2).
        #expect(fuzzyCorrect("the kubernetis cluster", dictionary: dict) == "the Kubernetes cluster")
    }

    @Test func exactTermUntouched() {
        #expect(fuzzyCorrect("run Kubernetes now", dictionary: dict) == "run Kubernetes now")
    }

    @Test func commonWordNotMangled() {
        // "the" is too short (len 3) -- never touched.
        #expect(fuzzyCorrect("the the the", dictionary: dict) == "the the the")
    }

    @Test func farWordLeftAlone() {
        #expect(fuzzyCorrect("a big elephant", dictionary: dict) == "a big elephant")
    }

    @Test func casePreservedTitlecase() {
        // "Parakit" -> "Parakeet", leading cap preserved.
        #expect(fuzzyCorrect("Parakit engine", dictionary: dict) == "Parakeet engine")
    }

    @Test func punctuationPreserved() {
        #expect(fuzzyCorrect("use Parakit, please", dictionary: dict) == "use Parakeet, please")
    }

    @Test func shortTokenBelowGateUntouched() {
        // "bat" is distance 1 from "cat" but len 3 -> gated out (nil threshold).
        #expect(fuzzyCorrect("a bat", dictionary: ["cat"]) == "a bat")
    }

    @Test func whitespaceLayoutPreserved() {
        #expect(fuzzyCorrect("two  spaces\there", dictionary: dict) == "two  spaces\there")
    }

    @Test func ambiguousMatchLeftAlone() {
        // "Kase" (len 4, threshold 1) is distance 1 from both "Case" (differs at
        // position 0) and "Kass" (differs at the last letter) -- neither wins.
        let d = ["Case", "Kass"]
        #expect(fuzzyCorrect("say Kase now", dictionary: d) == "say Kase now")
    }
}

struct EngineVocabularyMergeTests {
    @Test func appleEngineMergesScreenTermsNotAlreadyPresent() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["Xcode", "OmWhisper"],
            engineKind: .apple
        )
        #expect(result == ["OmWhisper", "Xcode"])
    }

    @Test func parakeetEngineAlsoMergesScreenTerms() {
        let result = mergeEngineVocabulary(
            customTerms: ["Parakeet"],
            screenTerms: ["FluidAudio"],
            engineKind: .parakeet
        )
        #expect(result == ["Parakeet", "FluidAudio"])
    }

    @Test func cloudEngineExcludesScreenTermsEntirely() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["Xcode", "SecretProjectName"],
            engineKind: .cloud
        )
        #expect(result == ["OmWhisper"])
    }

    @Test func cloudEngineWithNoCustomTermsSendsNothing() {
        let result = mergeEngineVocabulary(
            customTerms: [],
            screenTerms: ["Xcode"],
            engineKind: .cloud
        )
        #expect(result.isEmpty)
    }

    @Test func caseInsensitiveDedupeStillAppliesForNonCloudEngines() {
        let result = mergeEngineVocabulary(
            customTerms: ["OmWhisper"],
            screenTerms: ["omwhisper", "Xcode"],
            engineKind: .apple
        )
        #expect(result == ["OmWhisper", "Xcode"])
    }
}
