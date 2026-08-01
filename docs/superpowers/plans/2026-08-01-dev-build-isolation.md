# Dev-Build Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Debug builds identify as `com.omwhisper.mac.dev` ("OmWhisper Dev") with fully separate data, Keychain, instance guard, and no Sparkle — so a dev build can run beside installed 2.0.4 without touching its data. Per `docs/superpowers/specs/2026-08-01-dev-build-isolation-design.md`.

**Architecture:** Fork `PRODUCT_BUNDLE_IDENTIFIER` in the Debug build configuration only. Everything reading the live bundle ID (Keychain, SingleInstance matching) separates for free; the three hardcoded `com.omwhisper.mac` data paths consolidate onto one bundle-ID-aware `AppSupportDirectory` helper; the instance-guard ping channel and a new `isDevBuild` Sparkle gate read the live ID too.

**Tech Stack:** Swift 6 (MainActor-by-default), Xcode build settings, Swift Testing.

## Global Constraints

- **Release config must keep `PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac` and its display name** — shipping `.dev` would orphan every user's data and break Sparkle identity. Task 4 verifies both directions; do not skip it.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: new globals/statics follow existing patterns (`isRunningUnderTests` is a `nonisolated let` global in AppState.swift:41).
- pbxproj: build-settings edits only, never file references (file-system-synced groups).
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -6`.
- Commit style: emoji conventional commits.

---

### Task 1: Bundle-ID-aware data root, consolidated across all three call sites

**Files:**
- Modify: `omwhisper-native/AppSupportDirectory.swift`
- Modify: `omwhisper-native/Meetings/MeetingRecorder.swift` (`makeMeetingDirectory`, ~line 373)
- Modify: `omwhisper-native/ReplyAssist/ToneProfile.swift` (`toneFileURL`, ~line 34)
- Test: `omwhisper-nativeTests/AppSupportDirectoryTests.swift` (create)

**Interfaces:**
- Produces: `AppSupportDirectory.folderName(bundleID: String?) -> String` (pure); `resolve()` unchanged signature, now bundle-ID-aware. MeetingRecorder/ToneProfile lose their inline lookups.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing test**

Create `omwhisper-nativeTests/AppSupportDirectoryTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/AppSupportDirectoryTests 2>&1 | tail -5`
Expected: COMPILE FAILURE — `folderName` undefined.

- [ ] **Step 3: Implement**

`AppSupportDirectory.swift` — replace the body of the enum:

```swift
nonisolated enum AppSupportDirectory {
    /// Pure: the Application Support folder name for a bundle ID. Falls back to
    /// the production ID so a nil bundle ID (bare test runners) never invents a
    /// new location.
    static func folderName(bundleID: String?) -> String {
        bundleID ?? "com.omwhisper.mac"
    }

    static func resolve() -> URL? {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent(folderName(bundleID: Bundle.main.bundleIdentifier), isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
```

`MeetingRecorder.makeMeetingDirectory` — replace the inline lookup (keep stamp logic):

```swift
    nonisolated private static func makeMeetingDirectory(appName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: Date())
        guard let root = AppSupportDirectory.resolve() else {
            throw error("makeMeetingDirectory: no Application Support directory", -1)
        }
        let base = root
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp)_\(appName)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
```

`ToneProfile.toneFileURL` — same consolidation:

```swift
    static func toneFileURL() throws -> URL {
        guard let root = AppSupportDirectory.resolve() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("tone.md")
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/AppSupportDirectoryTests 2>&1 | tail -5`
Expected: PASS (3 tests).

- [ ] **Step 5: Full build + suite** (MeetingRecorder/ToneProfile compile + no behavior change while the ID is still production everywhere)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -6`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppSupportDirectory.swift omwhisper-native/Meetings/MeetingRecorder.swift omwhisper-native/ReplyAssist/ToneProfile.swift omwhisper-nativeTests/AppSupportDirectoryTests.swift
git commit -m "♻️ refactor: one bundle-ID-aware data root — consolidates 3 hardcoded lookups"
```

---

### Task 2: Instance-guard ping channel derived from the live bundle ID

**Files:**
- Modify: `omwhisper-native/SingleInstance.swift:26`

**Interfaces:**
- Produces: same `openHubNotification` symbol, name now `"<liveBundleID>.openHub"`. The single observer (`OmWhisperApp.swift:127`) references the symbol, so it follows automatically.

No new unit test (a one-line string composition on a `static let`; the existing suite compiling + Task 4's live side-by-side check is the verification, matching project convention).

- [ ] **Step 1: Implement**

Replace line 26:

```swift
    /// Cross-process ping the losing launch sends so the winner surfaces itself.
    /// A menu-bar app that just exits silently reads as "it didn't launch", which
    /// is exactly what makes someone launch it a third time.
    /// Derived from the live bundle ID so the .dev build and the installed app
    /// have separate channels — they can't hear each other's pings.
    static let openHubNotification = Notification.Name(
        "\(Bundle.main.bundleIdentifier ?? "com.omwhisper.mac").openHub")
```

- [ ] **Step 2: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -6`
Expected: TEST SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/SingleInstance.swift
git commit -m "🐛 fix: instance-guard ping channel keyed to live bundle ID"
```

---

### Task 3: `.dev` bundle ID + "OmWhisper Dev" name (Debug only) + Sparkle gate

**Files:**
- Modify: `omwhisper-native/AppState.swift` (global next to `isRunningUnderTests`, line 41)
- Modify: `omwhisper-native/OmWhisperApp.swift:84` (updater init)
- Modify: `omwhisper-native.xcodeproj/project.pbxproj` (app-target **Debug** configuration ONLY)

**Interfaces:**
- Produces: `isDevBuild: Bool` (nonisolated global). Debug builds: bundle ID `com.omwhisper.mac.dev`, display name "OmWhisper Dev", Sparkle never starts.

- [ ] **Step 1: Add the global**

In `AppState.swift`, directly below line 41's `isRunningUnderTests`:

```swift
/// True for Debug builds carrying the forked .dev bundle ID (see
/// docs/superpowers/specs/2026-08-01-dev-build-isolation-design.md). Gates
/// Sparkle: a dev build must never offer to replace itself from the live
/// appcast. Data/Keychain isolation need no gate — they key off the live
/// bundle ID directly.
nonisolated let isDevBuild = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
```

- [ ] **Step 2: Gate the updater**

`OmWhisperApp.swift:84` — change the init argument:

```swift
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: !isRunningUnderTests && !isDevBuild, updaterDelegate: nil, userDriverDelegate: nil
    )
```

(The About button already disables itself via `canCheckForUpdates`, which is false when the updater never started — no UI change needed.)

- [ ] **Step 3: Fork the Debug configuration**

The two `PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac;` occurrences (~lines 401/444) are the app target's Debug and Release configs — visually identical blocks, so identify Debug by the block's trailing `name = Debug;`, never by position:

```bash
python3 - <<'EOF'
import re
p = 'omwhisper-native.xcodeproj/project.pbxproj'
s = open(p).read()
blocks = s.split('PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac;')
assert len(blocks) == 3, f"expected exactly 2 occurrences, found {len(blocks)-1}"
# Which occurrence belongs to the Debug config? Look ahead in the text that
# FOLLOWS each occurrence for the config's closing 'name = Debug;'.
def is_debug(following):
    m = re.search(r'name = (Debug|Release);', following)
    return m and m.group(1) == 'Debug'
out = blocks[0]
for i, rest in enumerate(blocks[1:], 1):
    if is_debug(rest):
        out += ('PRODUCT_BUNDLE_IDENTIFIER = "com.omwhisper.mac.dev";\n'
                '\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "OmWhisper Dev";')
    else:
        out += 'PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac;'
    out += rest
open(p, 'w').write(out)
print("done")
EOF
```

- [ ] **Step 4: Verify both configurations from the build system itself**

```bash
xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|CFBundleDisplayName"
xcodebuild -showBuildSettings -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Release 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|CFBundleDisplayName"
```

Expected: Debug → `com.omwhisper.mac.dev` + `OmWhisper Dev`; Release → `com.omwhisper.mac` and NO display-name override. **Both greps must be run and read — a wrong Release value here is the one unshippable failure of this plan.**

- [ ] **Step 5: Full build + suite** (tests now run under the `.dev` ID — they must stay green, and they now write to the `.dev` data dir, no longer the production one)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -6`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/AppState.swift omwhisper-native/OmWhisperApp.swift omwhisper-native.xcodeproj/project.pbxproj
git commit -m "✨ feat: Debug builds are OmWhisper Dev (.dev bundle ID, no Sparkle)"
```

---

### Task 4: Verification pass — the checks that can fail

**Files:** none (verification only; fixes loop back into the task that broke).

- [ ] **Step 1: Built-product Info.plist**

```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build 2>&1 | tail -2
plutil -p ~/Library/Developer/Xcode/DerivedData/omwhisper-native-*/Build/Products/Debug/OmWhisper.app/Contents/Info.plist | grep -E "CFBundleIdentifier|CFBundleDisplayName"
```

Expected: `com.omwhisper.mac.dev` and `OmWhisper Dev`. (Glob may match multiple DerivedData dirs — use the one this checkout builds into.)

- [ ] **Step 2: Release script assumes nothing about the ID**

```bash
grep -n "com.omwhisper.mac" scripts/build-release.sh scripts/publish-release.sh 2>/dev/null
```

Expected: no data-path or identifier assumptions that the Debug fork could disturb (Release config is what these scripts archive; any hits must be Release-side and correct).

- [ ] **Step 3: Live side-by-side (user, real hardware — the exit criteria)**

1. With installed OmWhisper 2.0.4 running, launch the Debug build → **both stay alive** (guard no longer matches), menu bar shows two ॐ icons, About/hub says "OmWhisper Dev".
2. `ls ~/Library/Application\ Support/com.omwhisper.mac.dev/` → dev databases exist; production dir contents/mtimes untouched.
3. Dev Settings → Transcription/AI: providers that have keys in 2.0.4 show "no key" in dev (Keychain separated).
4. Onboarding replays on first dev launch (fresh profile — expected, and re-exercises that flow).
5. No Sparkle activity in dev (About's Check for Updates disabled).

- [ ] **Step 4: Commit any fixes; otherwise nothing to commit.**
