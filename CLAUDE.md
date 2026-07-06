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

- `TranscriptionEngine` — `func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptEvent, Error>`,
  where `TranscriptEvent = .partial(String) | .final(String)`. SpeechTranscriber's volatile/finalized
  results map directly onto this; Parakeet and cloud engines conform to the same shape. This
  replaces the Tauri app's VAD worker, sentinel channels, and two-pass decode entirely.
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

## Progress Tracker

| Milestone | Status | Notes |
|-----------|--------|-------|
| M0 — Repo + pipeline | ✅ Done | pbxproj configured (bundle ID, macOS 26.0 target, sandbox off, Swift 6 language mode); source skeleton; CLAUDE.md/README/CI/build-release.sh; committed shared xcscheme (`omwhisper-native`, not autocreated — see naming gotcha). Confirmed build+run in Xcode. |
| M1 — Core loop MVP | 🔶 In progress | `AppleEngine` (SpeechAnalyzer/SpeechTranscriber, streaming partial/final), `BufferConverter` (mic format → analyzer format), `GlobalHotkey` (system-wide Cmd+Shift+V via NSEvent monitors), `OverlayPanel`/`OverlayView` (non-activating NSPanel HUD), `AppState` orchestration (start/stop, permissions, paste-on-stop) all written. **Compiles clean** as of commit `410fd2a` (Xcode 26.6 / macOS 26.5 SDK) — the first compile surfaced five Swift 6 region-isolation / actor-isolation errors, all fixed (see commit). Next: live smoke test (grant mic + speech, dictate), then measure against the M1 sign-off criteria and run the WER spike vs. Parakeet. |
| M2–M5 | ⬜ Not started | See milestone descriptions above. |

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
