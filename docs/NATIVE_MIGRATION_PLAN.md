# OmWhisper → omwhisper-native Migration Plan

> Full rewrite of OmWhisper as a native Swift macOS app in a **new repo: `omwhisper-native`**.
> Written 2026-07-06. Companion to `DICTATION_GAP_ANALYSIS.md`.

## North star: match Claude Code's dictation

The rewrite's product goal (from `DICTATION_GAP_ANALYSIS.md`): make OmWhisper feel like Claude Code's dictation — which is a server-side streaming ASR — while offering the user the choice of local or cloud. Native macOS 26 makes this *easier*, not harder: SpeechTranscriber gives the streaming-partials pipeline as a system API instead of the hand-built one planned for the Tauri app.

Success criteria (the "80% bar", carried over and tightened):

1. Words appear **while you speak** — dimmed live partials in the overlay, < 1s behind speech, finalized on stop (Claude Code's exact interaction model).
2. Key-release → punctuated text in the target app in **< 700ms** typical.
3. Punctuation and capitalization work with **zero configuration** (in-engine, like Claude's).
4. Technical vocabulary respected via context hints (custom vocab → engine biasing / cloud keyterms; Claude Code's project-name/branch-hint trick).
5. PTT that starts instantly on keydown — already ahead of Claude Code's key-repeat warmup.

Where OmWhisper should *exceed* Claude Code: user-chosen backend (local Apple / local Parakeet / cloud streaming), works offline, works in every app (not just one CLI), and dictation history.

These criteria gate M1/M4 sign-off below.

## Locked decisions

| Decision | Choice | Consequence |
|---|---|---|
| Platform | **macOS 26+, Apple Silicon only** | SpeechTranscriber + Foundation Models always available — no fallback paths, no availability gating |
| Distribution | **Direct, Developer ID + notarization** | Full Accessibility paste + CGEventTap PTT allowed (App Store sandbox forbids both) |
| Tauri repo | **Freeze after parity** | Bug-fix-only until native parity, then archive; last Tauri release stays up for Windows users |
| UI | SwiftUI-first, AppKit where needed (`MenuBarExtra`, `NSPanel` overlay, `CGEventTap`) | — |
| Bundle ID | New: `com.omwhisper.mac` | Old app can coexist during beta; native app *imports* data from `com.omwhisper.app`'s dir |

## 1. Why the rewrite wins

macOS 26 system APIs replace roughly **60% of the Tauri codebase**:

| Tauri component (today) | Native replacement | Ship it? |
|---|---|---|
| whisper-rs + Parakeet/ort + Moonshine + engine cache | **SpeechTranscriber** (streaming, on-device, punctuated) | Deleted — API call |
| Silero VAD + worker thread + pre-roll/hysteresis | Built into SpeechTranscriber | Deleted |
| Two-pass decode + rolling context prompt | Built-in (volatile → finalized results) | Deleted |
| Auto-punctuation LLM pass + word-count guard | Built-in punctuation | Deleted |
| Model download manager + SHA256 verify | Only needed for optional Parakeet/cloud | ~90% deleted |
| llama-cpp-2 + qwen2.5-0.5b built-in polish | **Foundation Models framework** (system LLM) | Deleted — API call |
| cpal capture + resampling | AVAudioEngine | Rewritten, smaller |
| CGEventTap PTT, CGEventPost paste (Rust FFI) | Same APIs, first-class in Swift | Rewritten, cleaner |
| React UI + Tauri IPC + 80 commands + settings sync | SwiftUI + @Observable — no IPC boundary | Rewritten; god-file problem dissolves |
| rusqlite history | SQLite (GRDB) — **same schema**, import old DB | Ported |
| updater.rs + version.json | Sparkle | Replaced |
| rodio sounds | AVAudioPlayer | Trivial |

What carries over as *product knowledge*, not code: polish styles/prompts, vocabulary + word-replacement UX, onboarding flow, overlay design, theme (`#34d399` on `#0a0f0d`), ॐ branding, history schema.

## 2. Target architecture

Single Xcode project + local Swift packages. No storyboards.

```
omwhisper-native/
├── OmWhisper.xcodeproj
├── OmWhisper/                    # App target (thin)
│   ├── OmWhisperApp.swift        # @main, MenuBarExtra, window scenes
│   ├── AppState.swift            # @Observable root state (single source of truth — fixes Tauri settings sync debt)
│   └── Assets.xcassets           # Reuse icons from old repo scripts/generate_icons.py output
├── Packages/
│   ├── Transcription/            # protocol TranscriptionEngine (AsyncStream<TranscriptEvent>: .partial/.final)
│   │   ├── AppleEngine.swift     #   SpeechTranscriber (default, zero-config)
│   │   ├── ParakeetEngine.swift  #   FluidAudio CoreML (optional download, power users)
│   │   └── CloudEngine.swift     #   WebSocket streaming (Deepgram Flux / AssemblyAI), keyterms from vocabulary
│   ├── Polish/                   # protocol PolishBackend
│   │   ├── SystemLLM.swift       #   Foundation Models (default)
│   │   ├── Ollama.swift          #   ported HTTP client
│   │   └── CloudLLM.swift        #   OpenAI-compatible; API keys → Keychain (fixes plaintext-key debt)
│   ├── Capture/                  # AVAudioEngine mic capture, device selection, level meter
│   ├── Hotkeys/                  # CGEventTap PTT (Fn/CapsLock/modifiers) + Carbon RegisterEventHotKey for Cmd+Shift+V
│   ├── Paste/                    # frontmost-app capture, CGEventPost Cmd+V, clipboard save/restore
│   ├── History/                  # GRDB; one-time importer from ~/Library/Application Support/com.omwhisper.app/
│   └── UI/                       # Settings, History, Vocabulary, Onboarding, Overlay (NSPanel non-activating), StatsCard
├── docs/
│   └── (this plan, moved over)
├── scripts/
│   ├── build-release.sh          # xcodebuild archive → notarize (notarytool) → .dmg (create-dmg) → SHA256
│   └── bump-version.sh
├── .github/workflows/ci.yml     # build + test on macos-26 runner; notarized release on v* tags
└── CLAUDE.md                     # seed content in Appendix A
```

Key contracts:

- `TranscriptionEngine` — `func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<TranscriptEvent>` where `TranscriptEvent = .partial(String) | .final(String)`. SpeechTranscriber's volatile/finalized results map onto this directly; cloud and Parakeet engines conform to the same shape. This is the whole streaming story — no VAD, no sentinel channels, no two-pass plumbing.
- `AppState` is the single `@Observable` store; settings persist via `UserDefaults` with a one-time importer for the old `settings.json`. No component-level read-modify-write.

## 3. Milestones

**M0 — Repo + pipeline (2–3 days).** Create `omwhisper-native`, Xcode project, package skeleton, CI on `macos-26` runner, Developer ID signing + `notarytool` working end-to-end on a hello-world menu bar app. Do signing *first* — it's the highest-friction unknown and everything else queues behind it.

**M1 — Core loop MVP (1 week). The Claude-Code-feel milestone.**
Hotkey (Cmd+Shift+V) → AVAudioEngine capture → SpeechTranscriber streaming → **live partials in overlay (dimmed → solid on finalize)** → paste to frontmost app on stop, clipboard restore. Includes an accuracy spike: dictate 20 real technical sentences, compare SpeechTranscriber vs Parakeet WER on your voice. *Go/no-go gate: if SpeechTranscriber disappoints, promote ParakeetEngine to default and keep going — architecture is unchanged.* **Sign-off = north-star criteria 1–3 measured and met** (partial lag < 1s, stop-to-paste < 700ms, punctuation zero-config).

**M2 — Daily-driver parity (1–1.5 weeks).** Settings UI, PTT (Fn/CapsLock via CGEventTap), history + importer, vocabulary UI, sounds, launch-at-login, Sparkle updates, onboarding (shorter — no model download step), menu bar states.

**M3 — AI polish (1 week).** Foundation Models default backend, styles system (port prompts verbatim), Ollama + cloud backends, Keychain key storage, smart dictation flow (Cmd+Shift+B).

**M4 — Backend flexibility, the USP (1–1.5 weeks).** Cloud streaming engine (pick one provider first — Deepgram Flux for built-in end-of-turn, or AssemblyAI for keyterm prompting from vocabulary), Parakeet CoreML optional engine + minimal downloader, per-backend selector UI mirroring the polish pattern.

**M5 — Beta → release → freeze (1 week + beta soak).** Feature-parity audit vs. Appendix B, migrate landing page download links + version.json, beta via notarized .dmg, then tag Tauri repo `v-final`, mark README "maintenance mode (Windows)", archive after 1–2 months.

Total: **~6–7 weeks** part-time to a releasable native app, with a usable daily-driver at end of M2 (~2.5 weeks).

## 4. Risks & mitigations

1. **SpeechTranscriber accuracy on technical vocabulary** — the big unknown. Mitigated by the M1 spike and by ParakeetEngine as a same-interface fallback. Also test vocabulary-biasing hooks in the new Speech APIs; if weak, technical users route to Parakeet or cloud keyterms.
2. **Foundation Models availability** — requires Apple Intelligence enabled; some users disable it. Polish degrades gracefully to Disabled/Ollama/Cloud (transcription is unaffected — punctuation is in SpeechTranscriber).
3. **Swift/SwiftUI ramp-up** — steady but real. Mitigation: `MenuBarExtra` apps are a well-trodden template; the FluidInference `swift-scribe` repo is a working open-source reference for SpeechAnalyzer + capture + summaries.
4. **CGEventTap + TCC on macOS 26** — same permission model as today, but stable Developer ID signing actually *removes* the dev re-sign pain you have now.
5. **Notarization/signing setup** — one-time cost, front-loaded into M0. Needs a paid Apple Developer account.
6. **macOS 26-only shrinks the audience** in year one. Accepted trade-off; the frozen Tauri release covers stragglers.

## 5. Suggestions (opinions, not blockers)

- **Don't port; rebuild against the parity list.** Porting Rust idioms into Swift produces bad Swift. The old repo is the spec (Appendix B), not the source.
- **Keep the old repo read-only-visible during development** — point Claude Code / Cowork at both folders so the old implementation answers "how did we handle X?" questions.
- **Name the app just "OmWhisper"** — `-native` is a repo name, not a product name. Version it as 2.0.
- **Start M1 with the overlay, not the main window.** The overlay + paste loop *is* the product; the main window (history/settings/stats) is chrome. This inverts the Tauri app's build order and gets you to daily-driving fastest.
- **Write the history importer early (M2) and never break the old schema** — your own transcription history is the best regression dataset for the M1 accuracy spike.
- **CI on `macos-26` GitHub runners from day one** — catches SDK issues while the codebase is small.

---

## Appendix A — CLAUDE.md seed for omwhisper-native

```markdown
# OmWhisper Native — Claude Code Context

Native Swift rewrite of OmWhisper (menu-bar dictation for macOS). Supersedes the Tauri app
(github.com/rockykusuma/omwhisper — frozen, spec reference only).

- Platform: macOS 26+, Apple Silicon. SwiftUI + AppKit (MenuBarExtra, NSPanel overlay, CGEventTap).
- Distribution: Developer ID + notarization (NOT sandboxed — Accessibility paste + event taps required).
- Bundle ID: com.omwhisper.mac (imports data from com.omwhisper.app on first run).
- Transcription: `TranscriptionEngine` protocol → AppleEngine (SpeechTranscriber, default) /
  ParakeetEngine (FluidAudio CoreML) / CloudEngine (streaming WS). Events: .partial / .final.
- Polish: `PolishBackend` protocol → SystemLLM (Foundation Models, default) / Ollama / CloudLLM (Keychain keys).
- State: single @Observable AppState. No per-view settings read-modify-write.
- Theme: emerald #34d399 / #6ee7b7 / #2dd4bf on #0a0f0d. Logo: ॐ. Hotkeys: Cmd+Shift+V toggle, Cmd+Shift+B smart dictation, Fn/CapsLock PTT.
- Build: xcodebuild -scheme OmWhisper build test · release via scripts/build-release.sh
```

## Appendix B — Feature-parity checklist (from Tauri CLAUDE.md)

Core: menu-bar residency · Cmd+Shift+V toggle · PTT (Fn/CapsLock/R-Opt/R-Ctrl) · live streaming transcript in overlay (NEW — exceeds parity) · paste to frontmost app + clipboard restore w/ delay setting · mic device selection + level meter · recording sounds + volume · launch sound.
Data: history (search/export txt-md-json/delete/clear/auto-delete/storage info) · stats (totals, today, streak) · old-DB importer.
Vocabulary: custom vocab · word replacements (whole-word regex) · fuzzy toggle → maps to engine biasing/keyterms per backend.
AI: polish styles (6 built-in + custom CRUD) · smart dictation Cmd+Shift+B w/ raw fallback · backends Disabled/System/Ollama/Cloud · translate language picker · test connection.
App: onboarding · settings (General/Audio/Transcription/AI/About) · Sparkle updates + update banner · debug info + rotating logs · single-instance · error recovery (engine crash → toast, not app crash).
Explicitly dropped: Windows support · Whisper/Moonshine engines · VAD settings UI · model manager UI (except optional Parakeet download) · auto-punctuation toggle (always on via engine).
