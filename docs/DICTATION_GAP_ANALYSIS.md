# OmWhisper vs. Claude Code Dictation — Gap Analysis & Roadmap

> Goal: reach ~80% of the Claude Code dictation experience while staying 100% on-device.
> Written 2026-07-06. Builds on the July 5 quality overhaul (VAD pre-roll/hysteresis, two-pass decode, context prompt, auto punctuation).

---

## 1. How Claude Code's dictation actually works

The most important research finding: **Claude Code's dictation is not local.** Per the official docs, audio is streamed to Anthropic's servers for a proprietary server-side ASR; it's unavailable on API-key auth, Bedrock, Vertex, or SSH sessions. So the target isn't a better model — Parakeet TDT 0.6B is already competitive on accuracy — the target is replicating the *pipeline feel* of a streaming server ASR, locally.

What the Claude Code experience consists of:

| Element | Behavior |
|---|---|
| Streaming partials | Text appears word-by-word **while speaking**, dimmed, finalized on key release |
| Push-to-talk | Hold `Space` (key-repeat warmup) or modifier combo for instant start |
| Finalization | On release: transcript finalized and inserted at cursor; mix typing + dictation freely |
| Context hints | Coding vocab tuning + **dynamic hints**: project name and git branch injected automatically |
| Formatting | Punctuation/capitalization built into the ASR output |
| Language | Follows the `language` setting, ~20 languages, English fallback |

## 2. Where OmWhisper stands today

Recent work already closed the *accuracy* half of the gap: 300ms pre-roll + hysteresis (no clipped first words), two-pass decode (partials live, full-session re-decode on stop), rolling ~200-char context prompt (Whisper engines), and an auto-punctuation LLM pass with word-count guard.

What remains is mostly *latency and liveness*:

| Dimension | Claude Code | OmWhisper today | Gap |
|---|---|---|---|
| First text appears | ~instantly, mid-sentence | after 1.0s silence **+** utterance decode | **Large** — nothing shows while you talk |
| Stop → text lands | near-instant (finalize on release) | final re-decode (RTF×duration) + punctuation LLM round-trip + paste | **Medium** |
| PTT start | warmup or instant (modifier) | Fn/CapsLock CGEventTap (macOS) — instant | Parity ✅ |
| Punctuation | always on, in-model | only if an AI backend is configured | Medium |
| Context hints | dynamic (project, branch) | static custom vocabulary only | Medium |
| Formatting surface | streams into the prompt, dimmed | overlay indicator only; text pastes at end | Medium |
| Privacy | audio leaves device | fully local | **OmWhisper wins** |

## 3. Roadmap (prioritized)

### P0 — Streaming intra-utterance decode (the 80% unlock)

The single biggest perceptual difference. Today the VAD worker buffers an utterance and only sends it for decode after 1.0s of silence. Instead, while an utterance is active, re-decode the **growing utterance buffer** on a timer (~600–800ms cadence) and emit the result as a new segment kind (`is_partial: true`) that the UI overwrites in place. The existing utterance-end decode becomes the `is_final:false` confirmation, and the existing two-pass stays as the session-level `is_final:true`. Three-tier: *streaming draft → utterance-confirmed → session-final.*

Feasibility is good: Parakeet TDT on Metal has very low RTF, and the engine cache means no reload cost. Guard rails: cap streaming decode input at ~15s (decode only the active utterance, not the session), skip streaming ticks if the previous decode is still running (drop, don't queue), and only enable when RTF measured at startup is < ~0.3. Whisper-tiny may need this off by default; Parakeet on.

Surface it in the overlay (P0b): the overlay currently only shows a recording indicator. Render the streaming draft text there, dimmed, exactly like Claude Code's dimmed prompt text. This is the local analog of "text appears as you speak" without the risk of live-typing into arbitrary target apps.

### P1 — Instant-stop path

Make key-release → text-in-app feel immediate:

1. Run the punctuation LLM pass **incrementally during the session** on confirmed utterances, not as a blocking step after stop. On stop, only the last utterance needs punctuating.
2. Bound total stop latency: if final-pass + punctuation would exceed ~700ms, paste the best-available text immediately and skip the rest (the two-pass already keeps partials as source of truth on failure — extend that to a time budget).
3. Make the built-in qwen2.5-0.5b the **zero-config default** punctuation backend on macOS so `auto_punctuation` works out of the box instead of requiring Ollama/cloud setup.

### P2 — Dynamic context hints

Claude injects project name + git branch. OmWhisper's analog: at recording start, capture the **frontmost app** (already done for paste) and use it to (a) select a per-app vocabulary list, and (b) prepend app-appropriate hints to the Whisper `initial_prompt` and the punctuation LLM system prompt. Since Parakeet ignores prompts, routing hints through the LLM pass makes them engine-agnostic. Optional: when the frontmost app is a terminal/IDE, read the cwd's git branch/project name as hints — that's the literal Claude Code trick.

### P3 — Robustness & parity

Long sessions: the two-pass final decode caps at 2 min; chunk the final pass (overlapping windows, merge on word boundaries) instead of silently degrading. Language: expose a dictation language setting (Parakeet v3 is multilingual; Whisper `tiny.en` is not — gate model suggestions on language). Windows: Silero VAD via a standalone ort dependency (currently rides in on the macOS-only Parakeet dep) and a low-level keyboard hook (`SetWindowsHookEx WH_KEYBOARD_LL`) for PTT parity.

## 4. What "80% of Claude Code" means, concretely

Done when: (1) words appear in the overlay < 1s after being spoken, continuously; (2) key-release → punctuated text in the target app in < 700ms typical; (3) punctuation works with zero configuration; (4) technical vocabulary from the active app context is respected. Items 3–4 of the July 5 overhaul plus P0–P2 above get there — and OmWhisper keeps the one thing Claude Code can't offer: nothing ever leaves the device.

## 5. Suggested implementation order

| Step | Scope | Files | Effort |
|---|---|---|---|
| 1 | Streaming decode tick + `is_partial` segments | `audio/vad.rs`, `commands.rs`, `App.tsx`, `HomeView.tsx` | M |
| 2 | Overlay live transcript | `OverlayWindow.tsx`, `commands.rs` (event) | S |
| 3 | Incremental punctuation + stop-latency budget | `App.tsx`, `commands.rs` | M |
| 4 | Built-in LLM as default punctuation backend | `settings.rs`, `AiModelsView.tsx` | S |
| 5 | Per-app vocab + dynamic hints | `settings.rs`, `commands.rs`, `Vocabulary.tsx` | M |
| 6 | Chunked final pass, language setting, Windows VAD/PTT | multiple | L |
