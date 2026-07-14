# Meetings Pass — Auto-Stop + Speaker Diarization — Design

**Date:** 2026-07-14
**Status:** Approved (brainstorming), pending implementation plan(s)
**Area:** S3 Meetings. Surfaced by the first real Teams-call test (13 Jul): recording didn't auto-stop, and the transcript was an undifferentiated "You / Others" pile for a 4-person call.

## Overview

Two independent improvements to Meetings, brainstormed together:

- **Part A — Auto-stop + monitor-robust detection.** The recording never auto-stops because the end-signal (mic goes idle) is defeated by OmWhisper's own recorder holding the mic. Replace it with a call-app **window** signal read via Accessibility, which also fixes a multi-monitor gap in *start* detection.
- **Part B — Speaker diarization → interleaved transcript.** Today the "Others" (system-audio) track is every remote participant mixed into one blob. Split it into per-speaker turns and interleave chronologically with "You", so the transcript reads like the actual conversation.

Because they're independent (a detection signal vs. a transcription-pipeline rebuild), they will likely become **two implementation plans**. Both stay 100% on-device (recorded calls never egress — the standing S3 rule).

## Decisions (from brainstorming, 2026-07-14)

1. **Auto-stop signal = call-app window via AX** (not mic-idle, not others-track silence). Manual **Stop** remains the always-available override.
2. **Start detection also moves to the AX call-window check**, frontmost-independent — fixes the multi-monitor case where the call is on another display and the call app isn't frontmost when the mic goes active.
3. **Transcript shape = interleaved conversation** (chronological turns), not grouped-per-speaker.
4. **Labels = generic "Speaker 1…N"**, auto-detected count. Real names / voice enrollment is out of scope (that's F3). Renameable labels are a future enhancement.
5. **Diarized-transcript engine = WhisperKit** (ASR with segment timestamps) + **FluidAudio `DiarizerManager`** (speaker time-segments). Both on-device; both already dependencies.
6. **Graceful fallback** to today's `AppleEngine` **You/Others** transcript when no Whisper model is present or diarization yields ≤1 speaker.

## Why AX windows (multi-monitor rationale)

`AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` returns all of an app's windows regardless of which display they're on or whether the app is frontmost — window titles are display-agnostic. Both the mic-idle signal (blinded by self-recording) and the old `isFrontmost` signal break in the common multi-monitor setup (call on monitor 2, working on monitor 1). Keying detection to "does the call app have a call-like window" is robust to both.

---

## Part A — Auto-stop + monitor-robust detection

### Current behavior (the bug)

- `MeetingWatcher.tick()` polls `microphoneInUse()` (`kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input). Auto-stop = `.recording → .idle` when the mic is idle for `endDebounce` (8s).
- **Root cause:** `MeetingRecorder`'s aggregate device includes the physical mic as a sub-device, so while OmWhisper records, the mic reads "running" forever → the 8s idle auto-stop can never fire.
- Start detection uses `CallDetection.recognizedApp(bundleID: frontmost, isFrontmost: true, …)` — misses calls that aren't frontmost (multi-monitor).

### New behavior

- **New `CallDetection` capability:** `hasActiveCallWindow(pid: pid_t) -> Bool` — via `AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute`, read each window's `kAXTitleAttribute`, and return true if any matches the **existing** `CallDetection.hasCallLikeTitle(_:)` heuristic (`callLikeWords = ["call","calling","ringing","meeting","huddle"]`, already unit-tested). Frontmost- and display-independent. Only the AX enumeration is new; the title decision is reused as-is.
- **Start detection:** the mic-active poll recognizes a call when a known call app is running *and* `hasActiveCallWindow(pid:)` is true — no frontmost requirement. (Keep the bundle-ID allowlist; drop the `isFrontmost` gate.)
- **Auto-stop:** capture the call app's `pid` at record start. While `.recording`, poll `hasActiveCallWindow(pid:)` instead of the mic. When it's been false for the debounce, stop. `MeetingWatcher.nextState`'s `.recording` case switches its input from `micActive` to `callWindowPresent`.
- Manual `enterRecording`/`markDeclined`/Stop paths unchanged; manual Stop is the override.

### Risk

The call-like-title heuristic is per-app and imperfect (Teams keeps a persistent main window; some apps run the call in a helper process with a different pid). Manual Stop is the safety net; the heuristic is tuned against the known allowlist apps and logged for tuning. If a call app's call window can't be distinguished by title, auto-stop degrades to "manual only" for that app — no worse than today.

---

## Part B — Speaker diarization → interleaved transcript

### Pipeline (replaces `MeetingTranscriber.transcribeMeeting`)

For a recording directory with `me.caf` (mic = You) and `them.caf` (system audio = others):

1. **ASR with timestamps** (WhisperKit, batch/file): transcribe each track → `[Segment(text, start, end)]` at sentence granularity. `me.caf` segments are all speaker "You". (WhisperKit's `TranscriptionResult.segments` carry `start`/`end` — verify exact field names at plan time.)
2. **Diarize `them.caf`** via FluidAudio `DiarizerManager.performCompleteDiarization` → `[TimedSpeakerSegment(speakerIndex, startTimeSeconds, endTimeSeconds)]`. (`me.caf` is single-speaker — skip diarization.)
3. **Align** (pure, tested): assign each `them` text segment the `speakerIndex` whose diarization segment overlaps it most in time (fallback: nearest by midpoint if no overlap).
4. **Merge** (pure, tested): combine the `You` segments and the labeled `them` segments into one list sorted by `start`.
5. **Collapse** (pure, tested): fold consecutive same-speaker segments into a single turn.
6. **Render** (pure, tested): markdown — `**You:** …\n\n**Speaker 1:** …\n\n**You:** …`.

Steps 3–6 are pure functions over `[(text, start, end, speaker)]` — the heart of the feature, fully unit-testable with synthetic segments. Steps 1–2 are effectful (WhisperKit/FluidAudio), verified live.

### File / responsibility split

- **New pure logic** (WhisperKit/FluidAudio-free, testable): a `MeetingDiarization` type with `alignSpeakers`, `mergeByTime`, `collapseTurns`, `renderInterleaved` over a plain `TranscriptSegment` value type.
- **New effectful orchestrator**: the WhisperKit segment-ASR call + FluidAudio diarize call, in the app target (may import WhisperKit/FluidAudio). `MeetingTranscriber.transcribeMeeting` becomes: try diarized pipeline; on missing model / ≤1 speaker / error, fall back to the existing `AppleEngine` You/Others path (kept intact).
- `labeledTranscript(you:others:)` stays as the fallback renderer.

### Models

- WhisperKit model: reuses the user's downloaded variant (Large v3 present). If none downloaded → fallback path.
- FluidAudio diarizer models: auto-download on first diarized Transcribe (lazy, like Parakeet's model load), with progress surfaced on the Transcribe button. Not required until the user actually transcribes a meeting.

## Scope

- **In:** Part A (auto-stop + start detection), Part B (diarization + interleave), and the fallback.
- **Out (YAGNI):** speaker naming / voice enrollment (F3); renameable speaker labels; live/streaming diarization during recording (this stays a manual post-meeting batch, matching S3-2); per-app tuning beyond the current allowlist.
- `MeetingSummarizer` is unchanged; it benefits from better (interleaved) input for free.

## Testing

Pure unit tests (project convention — logic tested, effectful/UI verified live):
- **Part A:** `MeetingWatcher.nextState` driven by `callWindowPresent` instead of `micActive` (start + stop transitions); `hasCallLikeTitle` is already tested and reused unchanged.
- **Part B:** `alignSpeakers` (overlap → correct speaker; no-overlap fallback), `mergeByTime` (interleave order), `collapseTurns` (consecutive same-speaker folded), `renderInterleaved` (markdown), and the ≤1-speaker → fallback decision.

Live verification (user, real multi-person call):
- Multi-monitor: join a call on a second display, work on the main display → recording still starts (start-detection fix), and auto-stops after leaving the call (auto-stop fix).
- A real 3–4 person call → interleaved transcript with per-speaker turns that roughly track who spoke when; a call with a Whisper model absent → falls back to You/Others.

## Exit criteria

- Auto-stop fires within ~10s of the call window closing, without manual Stop, including when the call app is on another monitor / not frontmost.
- Start detection triggers for a call that is never frontmost (multi-monitor).
- A multi-person meeting produces an interleaved, per-speaker transcript; single-speaker or no-model cases fall back cleanly to You/Others.
- Everything on-device.
