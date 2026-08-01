//
//  MemoryExclusionsTests.swift
//  omwhisper-nativeTests
//
//  The user's own additions to the hardcoded exclusion floor.
//

import Testing
@testable import OmWhisper

struct MemoryExclusionsTests {
    @Test func emptyExclusionsExcludeNothing() {
        #expect(!MemoryExclusions.none.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }

    @Test func excludesAppByExactBundleID() {
        let e = MemoryExclusions(apps: ["com.apple.MobileSMS"])
        #expect(e.excludes(bundleID: "com.apple.MobileSMS", windowTitle: "Messages"))
        // Exact match only -- a prefix must not sweep up a different app.
        #expect(!e.excludes(bundleID: "com.apple.MobileSMS.helper", windowTitle: "Messages"))
        #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Messages"))
    }

    @Test func excludesTitleKeywordCaseInsensitively() {
        let e = MemoryExclusions(titleKeywords: ["Salary"])
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Salary review 2026"))
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "team salary.numbers"))
        #expect(!e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Budget 2026"))
    }

    @Test func blankKeywordNeverMatchesEverything() {
        // A user who adds a row and clears it must not silently disable all
        // capture -- an empty needle is contained in every string.
        for blank in ["", "   ", "\n", "\t "] {
            let e = MemoryExclusions(titleKeywords: [blank])
            #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"),
                    "blank keyword \(blank.debugDescription) must not match")
        }
    }

    @Test func keywordIsTrimmedBeforeMatching() {
        let e = MemoryExclusions(titleKeywords: ["  Salary  "])
        #expect(e.excludes(bundleID: "com.apple.Numbers", windowTitle: "Salary review"))
    }

    @Test func appAndKeywordListsAreIndependent() {
        let e = MemoryExclusions(apps: ["com.apple.MobileSMS"], titleKeywords: ["Salary"])
        #expect(e.excludes(bundleID: "com.apple.MobileSMS", windowTitle: "anything"))
        #expect(e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Salary review"))
        #expect(!e.excludes(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }

    // MARK: - The hardcoded floor is additive, not replaced

    @Test func hardcodedFloorStillAppliesWithEmptyUserLists() {
        // If a refactor ever routes capture through MemoryExclusions ALONE,
        // these stop being excluded and secrets start getting captured.
        #expect(ScreenContextReader.isExcluded(bundleID: "com.1password.1password", windowTitle: "Vault"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Safari", windowTitle: "Private Browsing"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: ".env"))
        #expect(!MemoryExclusions.none.excludes(bundleID: "com.1password.1password", windowTitle: "Vault"))
    }
}
