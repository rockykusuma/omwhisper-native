# Handoff: OmWhisper Native (Swift rewrite)

> Written 2026-07-06 for handoff to a new agent/session. Read this first, then
> `CLAUDE.md` (project conventions) and `docs/NATIVE_MIGRATION_PLAN.md` (full plan).

## What this project is

OmWhisper is free, offline-capable voice-to-text for macOS — a menu-bar dictation app.
This repo (`omwhisper-native`) is a **from-scratch Swift rewrite** (v2.0) of the original
Tauri/Rust app at `github.com/rockykusuma/omwhisper` (a sibling folder, `omwhisper`, checked
out alongside this one — it's the frozen functional spec, not code to port line-by-line).

Locked decisions (do not revisit without the user):
- **macOS 26+, Apple Silicon only.** No availability gating, no fallback paths.
- **Developer ID + notarization, direct download** — not the App Store (sandbox forbids the
  Accessibility-based paste and global event taps this app needs). `ENABLE_APP_SANDBOX = NO`.
- **Bundle ID `com.omwhisper.mac`**, Team ID `Y87BZN47C5`.
- **Tauri repo is frozen** after this reaches parity — stays up as the Windows release.
- **Swift 6 language mode**, explicitly requested by the user — see Concurrency section below.

North star: match Claude Code's dictation feel (streaming partials while you speak) while
keeping OmWhisper's actual differentiator — **user choice of local vs. cloud** transcription/
polish backends, not "always local."

## Where things stand

| Milestone | Status |
|---|---|
| M0 — Repo + pipeline | ✅ Done. Confirmed building and running in Xcode (menu bar icon shows). |
| M1 — Core loop MVP | 🔶 **Compiles clean** as of `410fd2a` (Xcode 26.6 / macOS 26.5 SDK). First compile surfaced five Swift 6 concurrency errors — all fixed. Not yet live-smoke-tested; that's the next thing to do. |
| M2–M5 | ⬜ Not started. |

Git log (all committed, `main` branch):
```
702b11e Fix scheme BuildableName: OmWhisper.app, not omwhisper-native.app
db0d333 M1: core loop (hotkey -> capture -> SpeechTranscriber -> overlay -> paste)
c046459 M0: repo skeleton, pbxproj config, CI, release script, docs
e1c2479 first commit
43bb1b4 Initial commit
```

**Push status**: the sandbox this work was done in cannot reach GitHub over SSH
(`git@github.com:rockykusuma/omwhisper-native.git`). Confirm with the user whether `main` has
actually been pushed — if not, `git push origin main` needs to happen from their machine.
The sibling `omwhisper` (Tauri) repo also had an unpushed commit (`bf4dff4`, docs) as of this
writing — worth checking too.

## What was actually verified vs. assumed

Be honest with the user about this distinction — it matters:

- **Verified by the user in Xcode**: M0 skeleton builds and runs (confirmed "Build and run
  successful. Menu bar icon is shown"). The scheme file was also auto-corrected by Xcode itself
  when it was next opened (`BuildableName` fixed from a wrong hand-authored guess to the correct
  `OmWhisper.app` — see commit `702b11e`), which is indirect evidence Xcode has opened/parsed the
  project fine since M1's changes landed too. **This does NOT confirm the M1 Swift code compiles**
  — the scheme XML and the Swift sources are independent; Xcode can fix up a scheme without
  building the app.
- **Not verified — no Swift toolchain exists in the agent sandbox**: all of M1's actual Swift
  code (`AppleEngine.swift`, `BufferConverter.swift`, `AudioCapture.swift` rewrite, `AppState.swift`
  rewrite, `GlobalHotkey.swift`, `OverlayPanel.swift`/`OverlayView.swift`). The SpeechAnalyzer/
  SpeechTranscriber API calls were cross-checked against three independent sources (Apple's own
  WWDC25 docs description, createwithswift.com's full tutorial, and a dev.to WWDC25 writeup) that
  agreed on the shape of the API, so confidence is reasonably high, but **this has never been
  compiled**. Swift 6 strict concurrency in particular (the `nonisolated`/`nonisolated(unsafe)`/
  `@preconcurrency` choices in `AudioCapture.swift`, `BufferConverter.swift`, `AppleEngine.swift`)
  is the part most likely to need small compiler-driven fixes — the reasoning is sound but Swift 6
  diagnostics can be picky about exact placement.

**Build is now green** (commit `410fd2a`) — the five first-compile errors were exactly the
concurrency ones predicted here (region isolation on the `sending` audio stream, `@Sendable`
convert block, `@MainActor`-default isolation on a helper, `@Observable`+`lazy`). **First thing to
do now**: grant mic + Speech Recognition + Accessibility permissions and run the live smoke test
(step 2 below), then measure against the M1 sign-off criteria.

## Key files (M1)

```
omwhisper-native/
├── AppState.swift                      # @MainActor orchestrator: toggleDictation -> startDictation/
│                                        # stopDictation, mic+speech permissions, transcript state, paste-on-stop
├── Transcription/
│   ├── TranscriptionEngine.swift       # protocol + TranscriptEvent(.partial/.final), both Sendable
│   ├── AppleEngine.swift               # default engine: SpeechAnalyzer + SpeechTranscriber, streaming
│   └── BufferConverter.swift           # AVAudioConverter wrapper: mic format -> analyzer format
├── Capture/AudioCapture.swift          # AVAudioEngine tap -> AsyncStream<AVAudioPCMBuffer>
├── Hotkeys/GlobalHotkey.swift          # system-wide Cmd+Shift+V via NSEvent monitors
├── Paste/PasteService.swift            # CGEventPost paste + clipboard restore (from M0, unchanged)
├── Polish/PolishBackend.swift          # stub protocol, wired in M3
└── UI/
    ├── OverlayPanel.swift              # non-activating NSPanel HUD
    ├── OverlayView.swift               # dimmed volatile + solid finalized transcript
    ├── MenuContent.swift               # menu bar dropdown (from M0, unchanged)
    └── SettingsView.swift              # settings window, General tab only (from M0, unchanged)
```

## Concurrency conventions (read before touching audio/background code)

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — everything is `@MainActor` by
default unless annotated otherwise. This is correct for UI/state (`AppState`, `GlobalHotkey`,
`OverlayPanel`) but wrong for `AVAudioEngine`'s tap callback, which runs on a real-time render
thread. The pattern used throughout, and expected for any new code in this area:

- `nonisolated` on functions that must run off MainActor (`AudioCapture.start()/stop()`,
  `AppleEngine.transcribe(_:)`).
- `nonisolated(unsafe)` + a real lock (`OSAllocatedUnfairLock`) on the specific mutable state
  those functions touch — never rely on actor isolation to protect state a background thread writes.
- `@preconcurrency import AVFoundation` wherever `AVAudioPCMBuffer`/`AVAudioConverter` cross a
  `Task` boundary (confirmed via web search: these types are not `Sendable` upstream).

Full detail and rationale is in `CLAUDE.md`'s "Concurrency" section — don't duplicate it here,
just know it exists and follow it.

## Immediate next steps, in order

1. **Build in Xcode, fix compile errors.** Expect concurrency-annotation nitpicks, possibly a
   locale/asset-availability edge case in `AppleEngine`. Push the fix commits.
2. **Grant permissions and do a live smoke test**: press Cmd+Shift+V, speak, press again — confirm
   the overlay shows dimmed partials that settle into solid finalized text, and that the text pastes
   into whatever app was frontmost.
3. **Measure against the M1 sign-off criteria** (see `docs/NATIVE_MIGRATION_PLAN.md` North Star):
   - Partial lag < 1s behind speech.
   - Stop → paste < 700ms typical.
   - Punctuation/capitalization correct with zero configuration.
4. **Run the accuracy spike**: dictate ~20 real technical sentences, eyeball SpeechTranscriber's
   WER against what the old Tauri app's Parakeet engine would have produced. If SpeechTranscriber
   disappoints on technical vocabulary, the fallback plan is promoting `ParakeetEngine` (not yet
   built — M4) to default; the `TranscriptionEngine` protocol already supports swapping backends.
5. Once M1 sign-off criteria are met, move to **M2 — Daily-driver parity** (Settings UI, PTT via
   CGEventTap, history + importer from the old app's SQLite DB, vocabulary UI, sounds,
   launch-at-login, Sparkle updates, onboarding). See milestone list in `CLAUDE.md`/migration plan.

## Things a new agent should NOT do

- Don't "port" the Tauri app's Rust code directly — it's the functional spec (parity checklist
  in migration plan Appendix B), not a template. Rust idioms make bad Swift.
- Don't remove the `nonisolated`/`nonisolated(unsafe)`/`@preconcurrency` annotations to "simplify"
  code that won't compile on the first try — the pattern is deliberate; the fix for a concurrency
  error here is almost always a placement/scope tweak, not reverting to MainActor-by-default.
- Don't hand-edit `project.pbxproj` to add/remove Swift files — the groups are file-system-synced
  (`PBXFileSystemSynchronizedRootGroup`); adding/removing a `.swift` file on disk is enough.
- Don't delete or "fix" `omwhisper-native.xcodeproj/xcshareddata/xcschemes/omwhisper-native.xcscheme`
  — it's hand-authored (no scheme existed on disk before M1) and now Xcode-corrected; without it,
  fresh clones (including CI) have no scheme to build.

## Where to find more context

- `CLAUDE.md` — day-to-day project conventions, tech stack, file map, concurrency rules, build commands.
- `docs/NATIVE_MIGRATION_PLAN.md` — the full plan: why the rewrite, target architecture, all
  milestones M0–M5, risks, and the Appendix B parity checklist against the old Tauri app.
- `docs/DICTATION_GAP_ANALYSIS.md` — why SpeechTranscriber was chosen over the old app's pipeline.
- Sibling repo `omwhisper` (Tauri) — the frozen functional spec; its own `CLAUDE.md` documents
  the old architecture in detail (VAD, two-pass decode, engine cache, etc.) for parity reference.
- Persistent agent memory (if available in the new session) has entries tagged
  `omwhisper-native-rewrite` and `omwhisper-dictation-quality-overhaul` with the decision history
  behind this rewrite and the reasoning that led to it.
