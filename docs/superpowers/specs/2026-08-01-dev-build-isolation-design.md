# Dev-Build Isolation — Design

**Date:** 2026-08-01
**Status:** Approved (brainstorming)
**Area:** Build configuration / app identity. Motivation: R runs installed OmWhisper 2.0.4 daily on the same Mac used for development. Today a Debug build shares the installed app's bundle ID, so it fights the single-instance guard, shares UserDefaults and the Keychain service, and — worst — opens the same `history.db`/`memory.db`/`meetings.db`, permanently applying unreviewed migrations to real data (the immediate trigger: SP1's `meetingIdentity` migration). Testing any branch locally currently risks the production install.

## Decision

Debug builds get their own identity: `PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac.dev` (Debug configuration only). Everything keyed off the live bundle ID then separates automatically; everything that *hardcodes* the production ID must switch to reading the live ID. Release stays byte-identical in behavior — `com.omwhisper.mac`, Sparkle on, same display name.

Decisions from brainstorming (2026-08-01):
1. **Sparkle is skipped entirely in dev builds** (bundle ID ending in `.dev`): a dev build must never offer to replace itself from the live appcast, and shouldn't hit the feed at all.
2. **Debug display name = "OmWhisper Dev"** so About/hub/app-switcher distinguish the two when they run side-by-side. Menu-bar icon unchanged (badging: YAGNI).
3. Lands on its own branch off `main`, *before* SP1 local testing — SP1's live verification then runs in the dev sandbox.

## What the code sweep found (2026-08-01)

Hardcoded `com.omwhisper.mac` **data paths** — the reason a pbxproj-only change is insufficient:
- `AppSupportDirectory.resolve()` — history.db / memory.db / meetings.db root.
- `MeetingRecorder.swift:379` — duplicates the same Application Support lookup for meeting audio directories instead of using the shared helper.
- `ReplyAssist/ToneProfile.swift:37` — duplicates it again for tone.md.

Already dynamic (separate for free once the ID forks): `Keychain.service` (= live bundle ID — dev builds and the test host stop sharing a Keychain service with production keys, closing the remaining KeychainTests-vs-real-keys risk class), `SingleInstance.enforce()` (matches live bundle ID → dev and 2.0.4 run side-by-side). One identity string to fix there: `SingleInstance.openHubNotification` is hardcoded, so dev and prod would hear each other's open-hub pings — derive it from the live bundle ID.

Left alone deliberately: `Logger(subsystem: "com.omwhisper.mac")` everywhere (cosmetic; DebugInfo reads the unified log by PID, not subsystem), the LegacyHistoryImporter's source path (`com.omwhisper.app` is the *old Tauri app's* dir, correct as-is), test-target bundle IDs.

## Design

1. **One shared data-root helper.** `AppSupportDirectory.resolve()` derives its folder name from `Bundle.main.bundleIdentifier ?? "com.omwhisper.mac"`; a pure `AppSupportDirectory.folderName(bundleID:)` carries the fallback logic and is unit-tested. `MeetingRecorder` and `ToneProfile` drop their duplicated lookups and call the shared helper — root-cause consolidation, not three parallel fixes.
2. **Instance-guard ping channel.** `openHubNotification` becomes `Notification.Name("\(bundleID).openHub")` via the same live-ID read.
3. **Sparkle gate.** `AppDelegate` skips `startingUpdater` (and the Check-for-Updates path shows disabled) when the bundle ID has the `.dev` suffix — one `isDevBuild` helper next to the existing `isRunningUnderTests` gate.
4. **pbxproj (build settings only, no file references):** Debug config gets `PRODUCT_BUNDLE_IDENTIFIER = com.omwhisper.mac.dev` and `INFOPLIST_KEY_CFBundleDisplayName = "OmWhisper Dev"`. Release config untouched.

## The critical invariant

**Release must keep `com.omwhisper.mac`.** Shipping a `.dev` ID would orphan every user's data and break Sparkle's update identity. Verification must check both directions:
- `xcodebuild -showBuildSettings -configuration Debug` → `com.omwhisper.mac.dev`; `-configuration Release` → `com.omwhisper.mac`.
- The built Debug app's Info.plist shows the `.dev` CFBundleIdentifier and "OmWhisper Dev" display name.
- `scripts/build-release.sh` greps clean of any bundle-ID assumption (it archives Release config; confirm, don't assume).

## Known consequences (accepted)

- A fresh dev profile starts empty: onboarding replays on first dev launch (useful — it re-exercises that flow), the legacy Tauri importer re-runs (read-only against the old app's dir), API keys must be re-entered in the dev build if cloud paths are tested.
- TCC prompts fire fresh for the `.dev` identity (mic, System Audio Recording, Accessibility, Calendar) — inherent to any new bundle identity, and re-signing already reset these for dev builds today.
- Two simultaneous instances both hold Fn-key monitors; data is isolated but hotkeys/PTT will double-fire — quit one before dictating seriously.
- Don't enable launch-at-login in the dev build: `SMAppService` would register the DerivedData copy.

## Testing

- Unit: `folderName(bundleID:)` (dev ID → dev folder, nil → production fallback).
- Live (the checks that can fail): dev build and 2.0.4 running simultaneously; `~/Library/Application Support/com.omwhisper.mac.dev/` created and populated while the production dir's contents stay untouched; dev Settings shows "no key" for providers that have keys in 2.0.4; no update check fires in the dev build; both `-showBuildSettings` reads above.

## Exit criteria

A Debug build runs beside installed 2.0.4 with separate settings, databases, Keychain entries, and no Sparkle activity, visibly named "OmWhisper Dev" — and a Release archive still identifies as `com.omwhisper.mac` with Sparkle intact.
