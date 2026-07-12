# OmWhisper for Windows — Native App Design

**Date:** 2026-07-12
**Status:** Approved design, pending implementation plan
**Repo:** new sibling repo `omwhisper-windows` (this doc lives in `omwhisper-native` because the Mac app is the functional spec, the same role the Tauri app played for the Mac rewrite)

## Context

OmWhisper 2.0 (macOS-native, this repo) is functionally complete through M4 + most of the
Smriti waves. Windows users were left on the frozen Tauri app, which was then deprecated
entirely (2026-07-08). This design brings OmWhisper back to Windows as a **native Windows
app** with no compromise on performance or functionality — the same bar the Mac rewrite set.

The Mac app leans on platform APIs with no Windows equivalent (SpeechTranscriber,
Foundation Models, AX tree, CGEventTap, non-activating NSPanel). Each needs a Windows-native
answer; this doc settles them.

## Decisions (settled during brainstorming, 2026-07-12)

| Question | Decision |
|---|---|
| Hardware/OS baseline | **Windows 11, any CPU** (x64 + ARM64). No GPU/NPU gate; local engines run on CPU, accelerate when hardware allows. Performance tiers per machine instead of hardware gating. |
| Tech stack | **C# / .NET (latest LTS at W0) + WPF.** WPF trivially handles this app's hard window problems (transparent click-through overlay, non-activating panels, tray, Win32 hooks) and excels at fully custom-styled UI — OmWhisper paints its own Porcelain design system, so stock-control fidelity (WinUI 3's draw) buys nothing. |
| Local ASR runtime | **sherpa-onnx** (official C# bindings): streaming partials on CPU, hotword biasing (= vocabulary), built-in VAD, runs Parakeet/Whisper/Zipformer under one API. |
| Default polish backend | **Built-in local model** via LLamaSharp (llama.cpp bindings), small instruct GGUF (~1–2B, Q4) downloaded on first enable — zero-config, on-device, matching the Mac's Foundation Models role. |
| V1 scope | **Dictation core** (M1–M4 equivalent). Smriti waves (context dictation, meetings, memory, reply assist, MCP) and the full hub are post-v1. |
| Distribution | **Direct download + Velopack** (installer + delta auto-updates), hosted on omwhisper.in alongside the Mac appcast. Code-signing certificate from the first public build. |
| Dev/verification | Real Windows 11 PC on hand. Live verification on real hardware is the acceptance mechanism, same discipline as the Mac. |
| Architecture | **Mirror the Mac contracts** in C# idioms. The Mac app is the functional spec; every already-litigated design decision carries over unless Windows forces a change. |

## §1 Platform mapping

| Concern | Mac (today) | Windows |
|---|---|---|
| Default local ASR | SpeechTranscriber | sherpa-onnx streaming (live partials, hotwords = vocab biasing) |
| Optional local engines | Parakeet (FluidAudio), Whisper (WhisperKit) | Same model families via sherpa-onnx offline mode — one runtime, all local engines |
| Cloud engines | 5 providers (AssemblyAI/Deepgram streaming; ElevenLabs/OpenAI/Groq batch) | Direct C# port — HTTP/WS logic is platform-neutral |
| Default polish LLM | Foundation Models (`SystemLLM`) | LLamaSharp + small instruct GGUF, downloaded on demand |
| Ollama / Cloud polish + Redactor | HTTP + NSRegularExpression | Direct port (HTTP + .NET Regex) |
| Mic capture | AVAudioEngine | WASAPI event-driven capture via NAudio; device picker via MMDeviceEnumerator; persist device ID, not name |
| Hotkey + PTT | NSEvent monitors / CGEventTap | One `WH_KEYBOARD_LL` low-level keyboard hook serving both toggle hotkey and hold-to-talk |
| Overlay HUD | Non-activating NSPanel | WPF window: `ShowActivated=false`, topmost, `WS_EX_NOACTIVATE\|TRANSPARENT\|TOOLWINDOW` (click-through), per-monitor-DPI aware (PerMonitorV2) |
| Paste | CGEventPost Cmd+V + clipboard save/restore | `SendInput` Ctrl+V + clipboard save/restore; foreground window captured via `GetForegroundWindow` before overlay shows |
| Menu bar | NSStatusItem | System tray `NotifyIcon` |
| History DB | GRDB SQLite | Microsoft.Data.Sqlite, same schema → the old Tauri Windows `history.db` imports via the same importer logic |
| Settings | UserDefaults | JSON file in `%APPDATA%\OmWhisper` |
| Secrets | Keychain | Windows Credential Manager |
| Updates | Sparkle + appcast.xml | Velopack + release feed on omwhisper.in |
| Launch at login | SMAppService | `Run` registry key |
| Concurrency | Swift 6 MainActor-default + `nonisolated` | .NET async/await + `Channel<T>`; UI marshaling via WPF `Dispatcher`; `AppState` touched only on the UI thread |

Two things are genuinely easier on Windows (relevant post-v1): system-audio capture for
meetings is WASAPI loopback (one flag — no CoreAudio process-tap saga), and screen-context
reading for S2 is UI Automation, more uniformly supported than AX.

PTT note: Fn/Globe doesn't exist on Windows. PTT defaults to a held Right-Ctrl; the toggle
hotkey defaults to `Ctrl+Alt+D`. Both deliberately avoid `Win+H` (Windows' own voice typing)
and `Ctrl+Shift+V` (paste-plain in browsers), and both are reconfigurable via the same
recorder-control UX the Mac app ships.

## §2 Architecture

Single WPF app project + one xUnit test project:

```
omwhisper-windows/
├── OmWhisper.sln
├── src/OmWhisper/
│   ├── App.xaml(.cs)            # tray-first, no window at launch
│   ├── AppState.cs              # single observable store — one source of truth, no per-view
│   │                            #   settings read-modify-write (the Mac/Tauri lesson)
│   ├── Transcription/
│   │   ├── ITranscriptionEngine.cs   # + TranscriptEvent (Partial | Final)
│   │   ├── SherpaEngine.cs           # default; persistent loaded model, reset() per session
│   │   └── Cloud/                    # CloudEngine dispatcher + 5 providers (ported)
│   ├── Capture/AudioCapture.cs  # WASAPI → IAsyncEnumerable<AudioChunk>, resample to 16k mono
│   ├── Hotkeys/                 # GlobalHotkey + PushToTalkMonitor (shared keyboard hook)
│   ├── Paste/PasteService.cs
│   ├── Polish/                  # IPolishBackend, LocalLLM, Ollama, CloudLLM, Redactor, PolishStyles
│   ├── Vocabulary/              # replacements + fuzzy correction (pure-logic port)
│   ├── History/                 # HistoryStore + LegacyHistoryImporter (Tauri history.db)
│   ├── Tray/
│   └── UI/                      # Overlay window, Settings/Hub window, Porcelain resources
├── tests/OmWhisper.Tests/       # xUnit
├── scripts/
└── .github/workflows/ci.yml    # windows-latest runner: build + test
```

**Key contract** (near-exact analog of the Swift `AsyncThrowingStream` contract, so every
engine behaves identically to its Mac sibling):

```csharp
IAsyncEnumerable<TranscriptEvent> TranscribeAsync(
    IAsyncEnumerable<AudioChunk> audio,
    IReadOnlyList<string> vocabulary,
    CancellationToken ct)
```

Threading follows the Mac's `nonisolated` discipline translated: audio callbacks and
inference run off the UI thread via `Channel<T>`; `AppState` mutations marshal through the
`Dispatcher`.

## §3 Core dictation loop

Same state machine as the Mac (`idle → starting → recording → stopping → pasting → idle`),
owned by `AppState`.

- **Audio:** WASAPI event-driven capture; resample to 16kHz mono float (sherpa-onnx input)
  in the capture layer (the `BufferConverter` role).
- **Hotkeys/PTT:** one keyboard hook installed at startup. Key-down starts capture instantly
  (sign-off criterion #5 unchanged). The hook matches registered chords only — it never logs
  keystrokes (both a privacy stance and an antivirus-heuristics defense).
- **Overlay:** one transparent click-through window, bottom-center of the monitor containing
  the focused window. All three overlay styles (Full / Orb / Whisper-line) port; the orb
  renders with WPF retained-mode shapes + animations, SkiaSharp is the escape hatch if ever
  needed, not a rewrite.
- **Paste:** clipboard save → set text → `SendInput` Ctrl+V → restore. Windows realities
  handled honestly:
  - **UIPI:** elevated (admin) target windows can't receive synthetic input from a
    non-elevated app — detect and surface "run OmWhisper as administrator to paste here"
    rather than silently no-op (the Mac's paste-hardening rule, ported).
  - Terminals wanting `Ctrl+Shift+V` get a per-app paste-keystroke override **later, not v1**.
  - Exclusive-fullscreen games won't show the overlay — documented limitation.
- **Sounds, tray-icon states, history writes, vocabulary post-processing** (replacements +
  fuzzy correction applied to both partials and finals in `AppState`): straight ports.

## §4 Engines + polish

- **SherpaEngine (default):** persistent loaded model (multi-second load — load once,
  `reset()` per session, the Mac `ParakeetEngine` lifecycle). The exact default model
  (streaming Zipformer vs Parakeet variant, size tier) is **deliberately undecided** — it is
  a W1 spike on the real PC measuring WER + partial latency + CPU load. Standing rule:
  remembered model/API facts must be verified against live docs/source before code is
  written (the AssemblyAI/WhisperKit/FluidAudio lesson). Vocabulary biases via sherpa
  hotwords. Model downloads: progress + task owned by `AppState` (downloads survive view
  navigation — the Mac download-state lesson, applied from day one), "Ready" means
  downloaded-on-disk, not loaded-in-memory.
- **Whisper (optional):** sherpa-onnx offline mode, transcribe-on-release, single `.Final` —
  same behavior as the Mac WhisperKit engine; exists for language coverage.
- **Cloud (optional):** the 5-provider dispatcher ports as-is. Per-provider keys in
  Credential Manager. Two ported rules: screen-auto-extracted terms never egress (only
  explicit custom vocabulary reaches cloud engines), and polish-bound text is redacted
  before egress.
- **Polish:** `IPolishBackend` with:
  - **LocalLLM** (LLamaSharp): exact model chosen in a W3 spike (~1–2B instruct, Q4,
    ~1GB download on first enable). Timeout + the Mac's **unconditional fail-safe**: any
    polish failure pastes the raw text — no failure mode ever drops dictated words.
  - **Ollama** (HTTP port) and **CloudLLM + Redactor** (regex registry ports near-verbatim
    to .NET Regex).
  - All 7 built-in styles + custom styles, Smart Dictation, Polish Selected Text
    (`SendInput` Ctrl+C capture; clipboard sequence number plays the changeCount role).

## §5 Milestones

| Milestone | Scope | Gate |
|---|---|---|
| **W0** | Repo, solution, CI (windows-latest), tray skeleton, signing cert ordered, Velopack pipeline stub | Builds; tray icon shows on the real PC |
| **W1** | Core loop MVP: hotkey/PTT → WASAPI → sherpa streaming → overlay partials → paste. Includes the default-model spike | Mac numbers on the real PC: partials <1s behind speech, stop-to-paste <700ms typical, PTT instant |
| **W2** | Daily-driver: Porcelain settings window, vocabulary UI, history + Tauri import, sounds, launch-at-login, Velopack live, onboarding | User daily-drives Windows dictation |
| **W3** | AI polish: LocalLLM + styles + Smart Dictation + Polish Selected + Ollama + Cloud + redactor | Polish parity with Mac |
| **W4** | Engine flexibility: Whisper batch + 5 cloud providers + selector UI | Engine parity |
| **W5** | Beta → signed release; omwhisper.in gets a Windows download again | Ship |

**Post-v1 waves (not gating v1):** S2 context dictation (UI Automation), meetings (WASAPI
loopback), reply assist, memory + MCP server, full hub window.

**Sign-off criteria = the Mac's five**, measured on the real PC: (1) live partials <1s
behind speech; (2) key-release → pasted text <700ms typical; (3) punctuation/caps zero-config;
(4) vocabulary respected via hotword biasing; (5) PTT instant on keydown.

## §6 Risks

1. **sherpa-onnx streaming quality vs SpeechTranscriber** — the mirror of the Mac's risk #1
   and the reason W1 contains the spike. Fallbacks: larger model tier on capable machines;
   cloud engines.
2. **Low-end CPU floor** — "any CPU" means a 2-core laptop must degrade gracefully: smaller
   model tier + honest first-run guidance; inference strictly off the UI thread so the app
   never freezes.
3. **Synthetic-input edge cases** — UIPI/elevated windows (detected + surfaced), RDP,
   exclusive-fullscreen games (documented), antivirus heuristics around keyboard hooks
   (signing cert + chord-match-only hook).
4. **SmartScreen reputation** — signed from the first public build; reputation accrues with
   downloads.

## §7 Testing & verification

Mirrors the Mac discipline exactly:

- **xUnit for every pure piece**: cloud providers (URL/body/parse), redactor, vocabulary
  logic, polish styles/prompts, state machines, overlay style mapping. The Mac test suite
  (289 tests) is the checklist of what to port.
- **Live verification on the real PC** for everything platform-touching: audio capture,
  hooks, overlay behavior over real apps, paste into real targets, model downloads. No
  platform claim is "done" until seen live — the Mac sessions proved the never-live-verified
  path is exactly where bugs hide.
- **No UI-automation tests** (same rule as Mac: unit tests + live human verification).

## Explicitly out of scope for v1

Smriti waves (S1–S5 equivalents) · full hub window (v1 ships a Porcelain settings window) ·
Microsoft Store packaging (possible v1.x addition) · per-app paste-keystroke overrides ·
Copilot+/NPU-specific tiers (Phi Silica etc.) · formal WER benchmark harness (same deferred
status as the Mac).
