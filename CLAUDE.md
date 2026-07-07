# OmWhisper Native — Claude Code Context

> Read this file at the start of every session to get full project context.

Native Swift rewrite of OmWhisper (menu-bar dictation for macOS), versioned **2.0**.
Supersedes the Tauri app (`github.com/rockykusuma/omwhisper` — frozen after native parity,
kept as the Windows release and as a spec/behavior reference — see `docs/NATIVE_MIGRATION_PLAN.md`).

---

## What This Project Is

- **Platform**: macOS 26+, Apple Silicon only. No availability gating, no fallback paths —
  SpeechTranscriber and Foundation Models are assumed present.
- **UI**: SwiftUI-first, AppKit where the platform demands it (`MenuBarExtra`, `NSPanel`
  non-activating overlay, `CGEventTap` for PTT).
- **Distribution**: Developer ID + notarization, direct download — **not** the App Store.
  The app is NOT sandboxed: Accessibility-based paste (`CGEventPost`) and global event taps
  require entitlements the App Store sandbox forbids.
- **Bundle ID**: `com.omwhisper.mac` (imports transcription history from the old app's
  `com.omwhisper.app` data dir on first run — see M2).
- **Apple Developer Team ID**: `Y87BZN47C5` (already set in `project.pbxproj`).
- **Language mode**: Swift 6 (`SWIFT_VERSION = 6.0`, all targets), with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES` — every
  unannotated declaration is `@MainActor` by default. See "Concurrency" below before writing
  anything that touches audio callbacks or background work.
- **Naming gotcha**: the Xcode *target* (and its scheme) is named `omwhisper-native` —
  `PRODUCT_NAME` is set to `OmWhisper` (so the built app/bundle display as "OmWhisper"), but
  `xcodebuild -scheme ...` and CI must use `omwhisper-native`. The scheme is committed at
  `omwhisper-native.xcodeproj/xcshareddata/xcschemes/omwhisper-native.xcscheme` — it is NOT
  autocreated on a fresh clone, so don't delete it.

## North Star

Match Claude Code's dictation feel — server-side streaming ASR, words appearing while you
speak — while keeping OmWhisper's actual differentiator: **user choice of local vs. cloud
transcription/polish backends**, not "always local." macOS is the primary target; Windows
stays on the frozen Tauri release.

Sign-off criteria (gate M1 and M4):
1. Live dimmed partials in the overlay, < 1s behind speech, finalized on stop.
2. Key-release → punctuated text pasted in the target app in < 700ms typical.
3. Punctuation/capitalization work with zero configuration (in-engine).
4. Technical vocabulary respected via context hints (custom vocab → engine biasing / cloud keyterms).
5. PTT starts instantly on keydown.

**Measured status (2026-07-07, live on-device, 9 dictation runs via `Logger(category: "Latency")`):**
- **#2 passes solidly**: stop-to-paste measured 108ms–697ms across every run, always under the 700ms bar.
- **#3 confirmed** live — pasted output shows correct capitalization/terminal punctuation with zero configuration.
- **#5 shipped** — Fn/Globe push-to-talk (`PushToTalkMonitor`), feels instant in practice (not separately latency-measured).
- **#1 not consistently met**: early runs measured ~4s and were initially suspected as an engine/setup bug — root-caused instead to human speech-onset delay after pressing the hotkey (the engine's own setup chain measured 8–42ms; mic buffers reach the analyzer within ~0.1s — see git history on `AppleEngine.swift`, since reverted). With speech content pre-decided to remove "what do I say" think-time, repeat runs landed at 1.3–2.0s, with one outlier at 0.89s — so sub-1s is achievable but not the norm. The gap is likely a mix of unavoidable human reaction time and the model's own minimum buffering before its first hypothesis; the current instrumentation (timed from recording-start, not actual speech-onset) can't separate the two. Untangling further needs VAD-based speech-onset detection — deferred, not pursued.
- **#4 shipped (2026-07-07)** — Vocabulary settings tab (custom words + whole-word
  replacements + fuzzy-match toggle), biasing `AppleEngine` via `AnalysisContext.contextualStrings`
  (the real mechanism — confirmed from the macOS 26 SDK's `Speech.swiftinterface`;
  `SpeechTranscriber` itself has no vocab parameter). Parakeet/cloud biasing follows the
  same `TranscriptionEngine.transcribe(_:vocabulary:)` parameter when those engines land (M4).

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI + AppKit (`MenuBarExtra`, `NSPanel`, `CGEventTap`) |
| State | Single `@Observable` `AppState` — no per-view settings read-modify-write (fixes the Tauri app's settings-sync debt) |
| Transcription | `TranscriptionEngine` protocol → `AppleEngine` (SpeechTranscriber, default) / `ParakeetEngine` (FluidAudio CoreML, optional) / `CloudEngine` (streaming WebSocket) |
| Polish | `PolishBackend` protocol → `SystemLLM` (Foundation Models, default) / `Ollama` / `CloudLLM` (OpenAI-compatible, keys in Keychain) |
| Capture | AVAudioEngine (`AudioCapture.swift`) |
| Paste | `CGEventPost` Cmd+V + clipboard save/restore (`PasteService.swift`) |
| History | SQLite (GRDB, M2) — same schema as the Tauri app, with a one-time importer |
| Updates | Sparkle (replaces `updater.rs` + `version.json`) |

## Project Structure

```
omwhisper-native/
├── omwhisper-native.xcodeproj/
│   ├── xcshareddata/xcschemes/omwhisper-native.xcscheme  # committed — see naming gotcha above
│   └── project.pbxproj                 # file-system-synced groups — no manual edits to add/remove files
├── omwhisper-native/                   # App target
│   ├── OmWhisperApp.swift              # @main — MenuBarExtra + Settings scene; starts the global hotkey
│   ├── AppState.swift                  # @MainActor @Observable root state + M1 core-loop orchestration
│   ├── Transcription/
│   │   ├── TranscriptionEngine.swift   # Core contract: protocol + TranscriptEvent (.partial/.final)
│   │   ├── AppleEngine.swift           # Default engine: SpeechAnalyzer + SpeechTranscriber (macOS 26)
│   │   └── BufferConverter.swift       # AVAudioConverter wrapper: mic format -> analyzer's format
│   ├── Capture/
│   │   └── AudioCapture.swift          # AVAudioEngine mic capture → AsyncStream<AVAudioPCMBuffer>
│   ├── Hotkeys/
│   │   └── GlobalHotkey.swift          # System-wide Cmd+Shift+V via NSEvent monitors
│   ├── Paste/
│   │   └── PasteService.swift          # Frontmost-app capture, CGEventPost paste, clipboard restore
│   ├── Polish/
│   │   └── PolishBackend.swift         # AI text-polish contract (stub — wired in M3)
│   ├── UI/
│   │   ├── MenuContent.swift           # Menu-bar dropdown (Start/Stop, Settings, Quit)
│   │   ├── SettingsView.swift          # Settings window (General tab only so far)
│   │   ├── OverlayPanel.swift          # Non-activating NSPanel HUD, bottom-center, never steals focus
│   │   └── OverlayView.swift           # SwiftUI content: status dot + live partial/final transcript
│   └── Assets.xcassets
├── omwhisper-nativeTests/              # Swift Testing (@testable import OmWhisper)
├── omwhisper-nativeUITests/            # XCUITest
├── docs/
│   ├── NATIVE_MIGRATION_PLAN.md        # Milestones M0–M5, architecture, risks, parity checklist (Appendix B)
│   └── DICTATION_GAP_ANALYSIS.md       # Why SpeechTranscriber vs. the Tauri app's pipeline
├── scripts/
│   └── build-release.sh                # xcodebuild archive → notarytool → .dmg → SHA-256
└── .github/workflows/ci.yml            # build + test on macOS runner
```

**Important**: the Xcode groups are **file-system-synchronized** (`PBXFileSystemSynchronizedRootGroup`).
Adding, moving, or deleting a `.swift` file on disk is enough — Xcode picks it up automatically.
Do not hand-edit `project.pbxproj` file references.

## Concurrency

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every type/function without an
explicit annotation is implicitly `@MainActor`-isolated. This is the right default for UI and
state (`AppState`, `GlobalHotkey`, `OverlayPanel` are all effectively `@MainActor`), but it is
**wrong** for anything that genuinely runs off the main thread — most importantly
`AVAudioEngine`'s tap callback, which fires on its own real-time render thread regardless of
what Swift infers. Two escape hatches are used deliberately, and any new code touching audio
buffers or background transcription work should follow the same pattern:

- **`nonisolated`** on functions/properties that must run (or be callable) off MainActor —
  e.g. `AudioCapture.start()/stop()`, `AppleEngine.transcribe(_:)`. A `nonisolated func`'s
  `Task { }` runs on the cooperative thread pool, not MainActor.
- **`nonisolated(unsafe)`** on the small pieces of mutable state those nonisolated code paths
  touch, paired with a real lock (`OSAllocatedUnfairLock` in `AudioCapture`) — never rely on
  actor isolation to protect state a background thread writes to.
- **`@preconcurrency import AVFoundation`** wherever `AVAudioPCMBuffer`/`AVAudioConverter`
  cross a `Task` boundary — these AVFoundation types are not `Sendable`, and we've asserted the
  actual safety invariant ourselves (single producer → single consumer per buffer) rather than
  fighting the compiler. `Speech` (SpeechAnalyzer/SpeechTranscriber) is a newer, concurrency-first
  API and needs no such treatment.

If a build error mentions an actor-isolation or Sendable violation in `AudioCapture`,
`BufferConverter`, or `AppleEngine`, check that the `nonisolated`/`nonisolated(unsafe)` markers
are still in place before assuming the fix is elsewhere.

## Key Contracts

- `TranscriptionEngine` — `func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, vocabulary: [String]) -> AsyncThrowingStream<TranscriptEvent, Error>`,
  where `TranscriptEvent = .partial(String) | .final(String)`. SpeechTranscriber's volatile/finalized
  results map directly onto this; Parakeet and cloud engines conform to the same shape. This
  replaces the Tauri app's VAD worker, sentinel channels, and two-pass decode entirely.
  `vocabulary` is read fresh at the start of each call (engines are rebuilt per session
  anyway) and biases `AppleEngine` via `AnalysisContext.contextualStrings`. Word replacements
  and fuzzy correction (`Vocabulary/VocabularyProcessing.swift`) are engine-agnostic
  post-processing, applied in `AppState` to both `.partial` and `.final` text — not part of
  the engine contract itself.
- `AppState` — the single `@Observable` store. Settings persist via `UserDefaults` (with a
  one-time importer for the old `settings.json` planned in M2). No component does its own
  read-modify-write of settings. Also owns the M1 core loop: `toggleDictation()` →
  `startDictation()`/`stopDictation()` wire `AudioCapture` → `AppleEngine` → `OverlayPanel` → `PasteService`.
- `PolishBackend` — `func polish(_ text: String, style: PolishStyle) async throws -> String`.

## Milestones (see `docs/NATIVE_MIGRATION_PLAN.md` for full detail)

- **M0 — Repo + pipeline** ✅ done: Xcode project, package/folder skeleton, CI, committed shared
  scheme, build-release script. Confirmed building and running in Xcode (menu bar icon shows).
- **M1 — Core loop MVP** (in progress): hotkey → capture → SpeechTranscriber streaming → live
  overlay partials → paste on stop. Implemented and **now compiles clean** (Xcode 26.6 / macOS 26.5
  SDK, commit `410fd2a` fixed the first-compile Swift 6 concurrency errors). Not yet live-smoke-tested
  or measured against the sign-off criteria (partial lag, stop-to-paste latency, accuracy spike vs.
  Parakeet) — that's the next step.
- **M2 — Daily-driver parity**: Settings UI, PTT, history + importer, vocabulary UI, sounds,
  launch-at-login, Sparkle, onboarding.
- **M3 — AI polish**: Foundation Models default backend, styles system, Ollama + cloud backends,
  Keychain key storage, smart dictation (Cmd+Shift+B).
- **M4 — Backend flexibility (the USP)**: cloud streaming engine, Parakeet CoreML optional engine,
  per-backend selector UI.
- **M5 — Beta → release → freeze**: parity audit, landing page + version.json migration, beta
  soak, then freeze the Tauri repo.
- **Phase S — Smriti integration** (decided 2026-07-07, see `docs/SMRITI_INTEGRATION_PLAN.md`):
  port Smriti's features into this app (smriti repo stays untouched; copy or rewrite here).
  S1 memory core (AX capture + FTS5 store) · S2 context-aware dictation (screen terms →
  `contextualStrings`) ⭐ · S3 meeting intelligence (consent-first, our engines) · S4 voice
  reply assist · S5 memory surfacing + MCP server · S6 website update (OmWhisper-centric).
  Order (priorities set 2026-07-07): M2 → S2 → M3 → S3 → S4 → S1 → S5 → M4 → S6/M5 —
  S4 ships window-context-only (no stored memory), gains memory snippets when S1 lands.
  "Learning the user" scope within Phase S = writing tone only (tone.md, in S4). All
  Smriti-derived features are OFF by default.
- **Phase 3 — Digital Twin** (decided 2026-07-07, after S5; same plan doc): nightly local
  distillation of the day's memory into a facts store (confidence/recency/source) +
  editable `profile.md` → twin-grounded replies & memory chat, auto-vocabulary learning
  from corrections, habit-level nudges. T1 profile distillation → T2 grounding →
  T3 auto-vocab → T4 habits. Local-only, inspectable, off by default; framed as "writes
  like you, knows what you know" — never as cloned judgment.

## Progress Tracker

| Milestone | Status | Notes |
|-----------|--------|-------|
| M0 — Repo + pipeline | ✅ Done | pbxproj configured (bundle ID, macOS 26.0 target, sandbox off, Swift 6 language mode); source skeleton; CLAUDE.md/README/CI/build-release.sh; committed shared xcscheme (`omwhisper-native`, not autocreated — see naming gotcha). Confirmed build+run in Xcode. |
| M1 — Core loop MVP | 🔶 Live, sign-off pending on #1 | Running live end-to-end (2026-07-07) after fixing three session-blocking bugs: SwiftUI `MenuBarExtra` silently dropping real clicks on macOS 26 (→ AppKit `NSStatusItem`); Hardened Runtime with no `audio-input` entitlement (mic permission silently denied, no prompt); an off-MainActor `SFSpeechRecognizer` callback crashing under Swift 6 isolation checks. Pulled forward from M2: push-to-talk (`PushToTalkMonitor`, hold Fn/Globe), start/stop sounds, paste-reliability hardening (Accessibility-gated, no more silent no-ops), richer menu-bar icon states. See "Measured status" under Sign-off criteria above for the numbers — #2/#3/#5 pass, #1 doesn't consistently, #4 shipped below. WER spike vs. Parakeet still owed. |
| M2 — Daily-driver parity | 🔶 In progress | PTT/sounds/paste-hardening/menu-bar states already shipped under M1 (see above). Vocabulary UI + engine biasing shipped (2026-07-07): `Vocabulary/VocabularyProcessing.swift` (whole-word replacements + length-gated bounded-Levenshtein fuzzy correction, ported from the Tauri app's `engine.rs`/`vocab_correct.rs`), `UI/VocabularySettingsView.swift`, `SettingsView` restructured into a `TabView` (General/Vocabulary). History + importer shipped (2026-07-07), per `docs/superpowers/specs/2026-07-07-history-importer-design.md`: GRDB added as SPM dependency (linked to both the app and test targets); `History/HistoryStore.swift` (GRDB `DatabaseQueue`, `transcriptions` table via `DatabaseMigrator`, record/fetchPage/search/delete/deleteAll/deleteOlderThan/storageInfo/exportAll — txt/md/json ports of the Rust `export_history`); `History/LegacyHistoryImporter.swift` (one-time read-only copy from the old app's `com.omwhisper.app/history.db`, gated by `hasImportedLegacyHistory`); `UI/HistoryView.swift` (paginated/searchable list, tap-to-expand rows, bulk-select delete, txt/md/json export via `NSSavePanel`, Clear All, Auto-Delete-After stepper) wired as a new `Window("History", id: "history")` scene + menu-bar item. `HistoryStore`/`TranscriptionEntry`/`LegacyHistoryImporter` are `nonisolated` (GRDB I/O has no MainActor affinity — see AppState concurrency note); `AppState.init()` opens the store and runs import+cleanup via a `nonisolated` background-Task launcher, matching the `AudioCapture` pattern. 33 new tests (`HistoryStoreTests`, `LegacyHistoryImporterTests`), all passing; live-verified against the real Tauri app's history.db (94 rows imported correctly, rendered in the History window). Also fixed a bug the `Window` scene introduced: macOS's window-state restoration (triggered by Xcode's Stop button killing the process uncleanly) was auto-reopening Settings/History at next launch, and closing that window then quit the whole app — fixed via `.defaultLaunchBehavior(.suppressed)` on both scenes plus `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returning `false` (menu-bar/`LSUIElement` apps must survive their last window closing). Launch-at-login shipped (2026-07-07): `AppState.launchAtLogin` wraps `ServiceManagement.SMAppService.mainApp` directly (no UserDefaults mirroring — the system login-item registry is its own source of truth), toggle added to `GeneralSettingsView`; live-verified both directions via `sfltool dumpbtm` (`disposition` flips enabled ⇄ disabled). Audio/About settings tabs shipped (2026-07-07), ported from the old app's Settings.tsx Audio/About sections (researched directly, not assumed — analytics/crash-reporting toggles, feedback form, and update UI deliberately dropped: no backing infra in this app, and updates are Sparkle's job). `Capture/AudioCapture.swift` gained mic device selection: `availableInputDevices()` via `AVCaptureDevice.DiscoverySession`, `start(preferredDeviceUID:)` resolves the UID to a `AudioDeviceID` via `AudioObjectGetPropertyData`/`kAudioDevicePropertyDeviceUID` and applies it with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` before `engine.start()` (AVAudioEngine has no higher-level device-picker API on macOS) — persisted UID, not name (old app matched by name, which breaks for two identical mic models). `AppState.soundVolume` (default 0.2, matches old app) applied via `NSSound.volume` in `SoundPlayer`. `UI/AudioSettingsView.swift` (input device picker, sound toggle + volume slider — no live level meter, matching the old app which only had one in the recording overlay, not Settings) and `UI/AboutSettingsView.swift` (version from `CFBundleShortVersionString`/`CFBundleVersion`, doc link, footer credit) added as new `SettingsView` tabs; "Recording sounds" toggle moved from General into Audio. Live-verified on real hardware: device picker lists actual devices (USB mic, Continuity iPhone mic, built-in), explicitly selecting the built-in mic and running a real start/stop dictation cycle worked end-to-end (proves the CoreAudio device-ID resolution path, not just the picker UI). Sparkle runtime wiring shipped (2026-07-07) — code only, not yet live (no signing key/appcast published, see below). Added as SPM dependency (app target only). `SPUStandardUpdaterController` on `AppDelegate` + "Check for Updates…" menu item (enabled state bound to `updater.canCheckForUpdates`). `SUFeedURL` = `https://omwhisper.in/appcast.xml` — chosen over a bare GitHub Pages URL because the Tauri app is being deprecated 2026-07-08 and `omwhisper.in` becomes this app's actual home (see `tauri-app-deprecation` memory); confirmed via research that `omWhisperWebApp`'s existing `version.json`/`updater.json` are Tauri-updater-format (JSON + minisign sig) and structurally incompatible with Sparkle's appcast.xml + EdDSA, so nothing there was reusable beyond the hosting slot. Hit and fixed a real Xcode issue along the way: `GENERATE_INFOPLIST_FILE`'s `INFOPLIST_KEY_*` synthesis only recognizes Apple's own known keys — a third-party key like `SUFeedURL` resolves fine as a build setting but is silently dropped from the generated Info.plist. Fixed with a `PBXShellScriptBuildPhase` ("Patch Info.plist (custom third-party keys)") that PlistBuddy-injects it after generation; needed `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app target too (Xcode's script-phase sandbox otherwise blocks the write with "Operation not permitted", and declaring the same path as a formal `outputPaths` entry instead causes a "Multiple commands produce Info.plist" conflict with the real generator). Live-verified: menu item appears, clicking it doesn't crash (fails gracefully — no appcast published yet), Info.plist correctly contains `SUFeedURL` alongside every pre-existing key. **Explicitly not done yet** (needs the user's go-ahead first — semi-irreversible/public): generating the real EdDSA signing keypair (`SUPublicEDKey` not in Info.plist), publishing an actual `appcast.xml`, and the `build-release.sh` `generate_appcast` step. Onboarding still not started — `docs/onboarding-prototype.html` exists in the working tree (not yet reviewed/wired in), deferred by user's choice. |
| M3–M5 | ⬜ Not started | See milestone descriptions above. |
| S1–S6 — Smriti integration | ⬜ Planned | `docs/SMRITI_INTEGRATION_PLAN.md` — starts after M2 (S2 first, S3 needs M3). |
| T1–T4 — Digital Twin (Phase 3) | ⬜ Planned | Same plan doc — after S5. Profile distillation → grounding → auto-vocab → habits. |

## Explicitly Dropped vs. the Tauri App

Windows support (stays on Tauri) · Whisper/Moonshine engines · VAD settings UI · model manager UI
(except an optional Parakeet download) · auto-punctuation toggle (always on, in-engine).

## Build

```bash
# Build + test
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test

# Release (archive → notarize → dmg)
bash scripts/build-release.sh
```

Requires: Xcode with macOS 26 SDK, a paid Apple Developer account for notarization, and
`APPLE_SIGNING_IDENTITY` / `APPLE_ID` / `APPLE_ID_PASSWORD` (app-specific password) /
`APPLE_TEAM_ID=Y87BZN47C5` set in the environment or a local `.env` (gitignored).

## Working Alongside the Old Repo

Keep `omwhisper` (Tauri) checked out alongside this repo during development — it's the
functional spec (see Appendix B of the migration plan), not code to port line-by-line. Rust
idioms ported directly into Swift produce bad Swift; rebuild against the parity checklist instead.
