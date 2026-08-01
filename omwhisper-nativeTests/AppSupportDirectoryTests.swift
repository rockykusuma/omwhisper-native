import Foundation
import Testing
@testable import OmWhisper

@Suite("AppSupportDirectory")
struct AppSupportDirectoryTests {
    @Test func folderNameUsesLiveBundleID() {
        #expect(AppSupportDirectory.folderName(bundleID: "com.omwhisper.mac.dev") == "com.omwhisper.mac.dev")
        #expect(AppSupportDirectory.folderName(bundleID: "com.omwhisper.mac") == "com.omwhisper.mac")
    }

    @Test func folderNameFallsBackToProductionID() {
        #expect(AppSupportDirectory.folderName(bundleID: nil) == "com.omwhisper.mac")
    }

    /// The test host runs as the app, so resolve() must land in the folder named
    /// after the live bundle ID — under the .dev fork this is what keeps tests
    /// out of the production data directory.
    @Test func resolveEndsWithLiveFolderName() {
        let dir = AppSupportDirectory.resolve()
        #expect(dir?.lastPathComponent == AppSupportDirectory.folderName(bundleID: Bundle.main.bundleIdentifier))
    }
}
