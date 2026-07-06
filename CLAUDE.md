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
├── omwhisper-native.xcodeproj/         # Xcode project (file-system-synced groups — no manual pbxproj edits to add/remove files)
├── omwhisper-native/                   # App target
│   ├── OmWhisperApp.swift              # @main — MenuBarExtra + Settings scene
│   ├── AppState.swift                  # @Observable root state, single source of truth
│   ├── Transcription/
│   │   └── TranscriptionEngine.swift   # Core contract: protocol + TranscriptEvent (.partial/.final)
│   ├── Capture/
│   │   └── AudioCapture.swift          # AVAudioEngine mic capture → AsyncStream<AVAudioPCMBuffer>
│   ├── Paste/
│   │   └── PasteService.swift          # Frontmost-app capture, CGEventPost paste, clipboard restore
│   ├── Polish/
│   │   └── PolishBackend.swift         # AI text-polish contract (stub — wired in M3)
│   ├── UI/
│   │   ├── MenuContent.swift           # Menu-bar dropdown (Start/Stop, Settings, Quit)
│   │   └── SettingsView.swift          # Settings window (General tab only so far)
│   └── Assets.xcassets
├── omwhisper-nativeTests/              # Swift Testing (@testable import OmWhisper)
├── omwhisper-nativeUITests/            # XCUITest
├── docs/
│   └── NATIVE_MIGRATION_PLAN.md        # Milestones M0–M5, architecture, risks, parity checklist (Appendix B)
├── scripts/
│   └── build-release.sh                # xcodebuild archive → notarytool → .dmg → SHA-256
└── .github/workflows/ci.yml            # build + test on macOS runner
```

**Important**: the Xcode groups are **file-system-synchronized** (`PBXFileSystemSynchronizedRootGroup`).
Adding, moving, or deleting a `.swift` file on disk is enough — Xcode picks it up automatically.
Do not hand-edit `project.pbxproj` file references.

## Key Contracts

- `TranscriptionEngine` — `func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<TranscriptEvent, Error>`,
  where `TranscriptEvent = .partial(String) | .final(String)`. SpeechTranscriber's volatile/finalized
  results map directly onto this; Parakeet and cloud engines conform to the same shape. This
  replaces the Tauri app's VAD worker, sentinel channels, and two-pass decode entirely.
- `AppState` — the single `@Observable` store. Settings persist via `UserDefaults` (with a
  one-time importer for the old `settings.json` planned in M2). No component does its own
  read-modify-write of settings.
- `PolishBackend` — `func polish(_ text: String, style: PolishStyle) async throws -> String`.

## Milestones (see `docs/NATIVE_MIGRATION_PLAN.md` for full detail)

- **M0 — Repo + pipeline** (current): Xcode project, package/folder skeleton, CI, Developer ID
  signing + notarization working end-to-end on a hello-world menu bar app.
- **M1 — Core loop MVP**: hotkey → capture → SpeechTranscriber streaming → live overlay partials
  → paste on stop. Includes a WER accuracy spike vs. Parakeet. Go/no-go gate on SpeechTranscriber.
- **M2 — Daily-driver parity**: Settings UI, PTT, history + importer, vocabulary UI, sounds,
  launch-at-login, Sparkle, onboarding.
- **M3 — AI polish**: Foundation Models default backend, styles system, Ollama + cloud backends,
  Keychain key storage, smart dictation (Cmd+Shift+B).
- **M4 — Backend flexibility (the USP)**: cloud streaming engine, Parakeet CoreML optional engine,
  per-backend selector UI.
- **M5 — Beta → release → freeze**: parity audit, landing page + version.json migration, beta
  soak, then freeze the Tauri repo.

## Explicitly Dropped vs. the Tauri App

Windows support (stays on Tauri) · Whisper/Moonshine engines · VAD settings UI · model manager UI
(except an optional Parakeet download) · auto-punctuation toggle (always on, in-engine).

## Build

```bash
# Build + test
xcodebuild -scheme OmWhisper -project omwhisper-native.xcodeproj build test

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
