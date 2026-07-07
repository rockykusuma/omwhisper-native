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
}
