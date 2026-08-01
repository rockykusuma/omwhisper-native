//
//  ScreenContextReaderTests.swift
//  omwhisper-nativeTests
//

import Testing
@testable import OmWhisper

struct ScreenContextReaderTests {
    @Test func excludesKnownPasswordManagers() {
        #expect(ScreenContextReader.isExcluded(bundleID: "com.1password.1password", windowTitle: "Vault"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Passwords", windowTitle: "Passwords"))
    }

    @Test func excludesPrivateBrowsingByTitle() {
        #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.Safari", windowTitle: "Private Browsing"))
        #expect(ScreenContextReader.isExcluded(bundleID: "com.google.Chrome", windowTitle: "New Incognito Tab"))
    }

    @Test func allowsOrdinaryApps() {
        #expect(!ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: "Untitled"))
    }

    // MARK: - dotenv files

    @Test func excludesDotEnvHoweverTheEditorDecoratesIt() {
        // Real window titles across the editors that actually open these.
        for title in [
            ".env",                              // TextEdit, Xcode
            ".env — omwhisper-native",           // VS Code
            "~/proj/.env.local (~/proj) - VIM",  // terminal vim
            "docs/.env.example",                 // path-prefixed
            ".ENV",                              // case-insensitive
            "Editing .env.production now",       // mid-title
        ] {
            #expect(ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: title),
                    "should have excluded: \(title)")
        }
    }

    @Test func doesNotSweepUpMerelyEnvLookingTitles() {
        // ".env" must match a whole path component -- a substring check would
        // wrongly swallow all of these.
        for title in [
            ".environment-setup.md",
            "environment.swift",
            "Development notes",
            "env.example",  // no leading dot: not the dotenv convention
        ] {
            #expect(!ScreenContextReader.isExcluded(bundleID: "com.apple.TextEdit", windowTitle: title),
                    "should NOT have excluded: \(title)")
        }
    }
}
