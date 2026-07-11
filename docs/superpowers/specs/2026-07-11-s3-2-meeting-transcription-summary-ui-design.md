# S3 Sub-project 2 — Meeting Transcription, Summary & UI — Design

**Date:** 2026-07-11
**Milestone:** Phase S, S3 sub-project 2. S3-1 (meeting detection → consent → dual-track
recording) shipped 2026-07-08; **this turns those recordings into transcribed, summarized,
browsable meetings.** Completes S3.

## Goal

After a call is recorded (S3-1 writes `me.caf` + `them.caf` per meeting), let the user open the
meeting and get a speaker-labeled transcript plus a summary + action items — all on-device.

## Decisions (2026-07-11)

- **Manual trigger**: a per-meeting "Transcribe & Summarize" button (matches S5.1's "Generate
  Chronicle" — no background-job orchestration). Recording-stop inserts the meeting row so it
  shows immediately as "Recorded"; the button fills in transcript + summary.
- **One pass**: transcription + store + summary + browse UI ship together.
- **Strictly on-device**: meeting transcription uses the **Apple engine** and summary uses
  **`SystemLLM`**, *regardless* of the user's dictation/polish backend. Recorded calls never
  egress — "your calls never leave this Mac." (Cloud/Ollama/Parakeet are not offered for
  meetings.)
- **Dual-track labeled** ("You" = mic, "Others" = system audio), no turn-by-turn interleaving —
  the `TranscriptEvent` contract exposes no per-segment timestamps, so time-merging two tracks
  is out of scope.

## Background (verified against current code)

- **S3-1 output** (`Meetings/MeetingRecorder.swift`): each meeting is a directory
  `{appSupport}/com.omwhisper.mac/meetings/{yyyy-MM-dd_HHmm}_{appName}/` containing `me.caf`
  (mic, mono float32 @48k) and `them.caf` (system audio, stereo float32 @48k). `stop()` flushes
  both files; `meetingRecorder.meetingDirectory` is the current dir.
- **Meeting lifecycle wiring** (`AppState`): `meetingWatcher.onStartRecording = { appName in try meetingRecorder.start(appName:) }`
  and `onStopRecording = { Task { await meetingRecorder.stop() } }`. The stop closure is where a
  `MeetingStore` row gets inserted (after `stop()` completes and the files exist).
- **Transcription contract** (`TranscriptionEngine`): `transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>, vocabulary: [String]) -> AsyncThrowingStream<TranscriptEvent, Error>`.
  `AppleEngine` converts fed buffers to the analyzer format via `BufferConverter`, so a recorded
  file can be transcribed by reading it into buffers and yielding them into an `AsyncStream`,
  finishing the stream, and collecting the `.final` events.
- **Summary precedent** (`Memory/Chronicler.swift`, S5.1): map-reduce over long text through
  `SystemLLM` (whose `polish()` has a 5s/~2000-char envelope) — `chunk` greedily packs blocks to
  ≤1,800 chars, each summarized (map), the concatenation summarized once more (reduce), via
  fixed-UUID internal `PolishStyle`s never shown in the AI picker. Meetings reuse this *pattern*
  (a focused `MeetingSummarizer`, not a Chronicler refactor).
- **Store precedent** (`Memory/MemoryStore.swift`): GRDB `DatabaseQueue`, a table + FTS5 kept in
  sync via `synchronize(withTable:)`, `nonisolated` (no MainActor affinity). `AppSupportDirectory.resolve()`
  (S5.2) resolves the shared app-support dir.
- **Hub section precedent** (`UI/HubMemorySectionView.swift`): a settings bar (toggle) over a
  browse UI, all Porcelain (`omRowCard`, `Color.Porcelain.*`); `MemoryChroniclesView`'s
  `NavigationSplitView` list+detail is the browse shape.

## Architecture

### 1. `Meetings/MeetingStore.swift` (new, GRDB, separate `meetings.db`)

`nonisolated final class MeetingStore` (mirrors `MemoryStore`). A `meetings.db` in the app
support root (`AppSupportDirectory.resolve()` + `"meetings.db"`) — separate from `history.db`/
`memory.db` (recorded calls are their own sensitivity class; wipe independently).

```
nonisolated struct Meeting: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var startedAt: String        // ISO8601
    var appName: String
    var directory: String        // absolute path to the meeting dir
    var durationSeconds: Double
    var transcript: String?      // nil until transcribed
    var summary: String?         // nil until summarized
    var createdAt: String
}
```

Display status is *derived*, not stored: `summary != nil` → "Summarized"; `transcript != nil`
→ "Transcribed"; else "Recorded".

Methods (mirroring `MemoryStore`'s shapes): `insert(_:) -> Int64`,
`setTranscriptAndSummary(id:transcript:summary:)`, `fetchPage(offset:limit:)`, `search(_:limit:)`,
`get(id:)`, `delete(id:)` (also removes the meeting directory on disk),
`deleteAll()` (removes rows **and** every meeting directory), `storageInfo()`. Schema via
`DatabaseMigrator`; FTS5 virtual table over `transcript`+`summary` synced with
`synchronize(withTable:)`. `dbQueue` internal (not private) so tests can seed, matching
`MemoryStore`.

### 2. `Meetings/MeetingTranscriber.swift` (new, `nonisolated`)

- `static func labeledTranscript(you: String, others: String) -> String` — **pure, tested**:
  returns markdown `**You:**\n{you}\n\n**Others:**\n{others}`, omitting a track whose text is
  empty/whitespace; returns "" when both are empty.
- `static func transcribeFile(_ url: URL, engine: TranscriptionEngine) async throws -> String` —
  effectful: `AVAudioFile(forReading:)`, read the whole file in buffer chunks, yield each into an
  `AsyncStream<AVAudioPCMBuffer>`, `finish()` it, feed `engine.transcribe(stream, vocabulary: [])`,
  and join every `.final` payload (space-separated). Empty/unreadable file → "".
- `static func transcribeMeeting(directory: URL, engine: TranscriptionEngine) async throws -> String` —
  transcribes `me.caf` (→ you) and `them.caf` (→ others) sequentially, returns
  `labeledTranscript(you:others:)`.
- Engine is passed in; `AppState` always passes a fresh `AppleEngine()` (local-only — see
  Decisions). Vocabulary is intentionally empty (a recorded meeting has no live screen context).
- **Risk / live-verification**: feeding a recorded file through the streaming `AppleEngine` is
  the one unproven path. `AppleEngine` converts input buffers via `BufferConverter` and
  SpeechAnalyzer is built for long-form audio, so this should hold — but it is the thing to
  verify live first. If it fails, the fallback is a file-based `SFSpeechRecognizer`
  (`SFSpeechURLRecognitionRequest`); noted, not built.

### 3. `Meetings/MeetingSummarizer.swift` (new, `nonisolated`)

Focused map-reduce over the transcript through a `PolishBackend`, mirroring `Chronicler`:
- `static func chunk(_ text: String, limit: Int = 1800) -> [String]` — **pure, tested**: greedily
  packs paragraph blocks to ≤`limit` chars; a single oversized block gets its own chunk.
- `static func generate(transcript: String, polish: PolishBackend) async throws -> String` —
  map each chunk through a fixed-UUID internal `PolishStyle` (meeting-chunk-summarizer), then one
  reduce call through another (meeting-writer) that emits markdown: a short **Summary** paragraph
  + an **Action items** bullet list. The two hidden styles live in `PolishStyles` (fixed UUIDs,
  `isBuiltIn: true`, never surfaced in the AI picker — same pattern as Chronicler's two).
- `AppState` always passes `systemLLM` (local-only).

### 4. `AppState`

- `let meetingStore = try? MeetingStore(...)` opened in `init()` independently (one store failing
  to open must not affect the others), guarded by `isRunningUnderTests`.
- Capture `meetingStartedAt: Date?` + `meetingAppName: String?` when `onStartRecording` fires.
- Extend the `onStopRecording` closure: after `await meetingRecorder.stop()`, if a
  `meetingDirectory` exists, insert a `Meeting` row (startedAt, appName, directory,
  durationSeconds computed from `me.caf`'s `AVAudioFile.length / sampleRate`, transcript/summary
  nil). Wrapped so a store failure only logs.
- `func transcribeMeeting(id: Int64) async throws -> Meeting` — the view's only path: `get(id:)`,
  `MeetingTranscriber.transcribeMeeting(directory:, engine: AppleEngine())`, then — if
  `SystemLLM.isAvailable()` — `MeetingSummarizer.generate(transcript:, polish: systemLLM)`; store
  both via `setTranscriptAndSummary`; return the updated meeting. If Foundation Models is off,
  store the transcript with `summary == nil` (transcript alone is still useful) and surface the
  same one-time nudge used elsewhere. `systemLLM` stays private.
- Gating note: unlike Chronicler, meeting transcription does **not** require the polish backend
  to be `.system` — it always uses `AppleEngine` for transcription and only the *summary* needs
  `SystemLLM`. So a meeting is always transcribable on-device; only the summary depends on Apple
  Intelligence being on.

### 5. UI — `UI/HubMeetingsSectionView.swift` (new)

Replaces `MeetingsSettingsView()` at `HubShellView`'s `.meetings` case (like
`HubMemorySectionView` replaced the plain Memory views). Structure:
- A compact top bar with the "Detect and record meetings" toggle (`$state.meetingsEnabled`,
  `.tint(Color.Porcelain.emerald)`) — the only control `MeetingsSettingsView` had, inlined here.
- A `NavigationSplitView`: sidebar = searchable list of meetings (`omRowCard` rows: app name,
  date, duration, derived status), detail = the selected meeting:
  - Header (app · date · duration).
  - A "Transcribe & Summarize" button (label "Re-transcribe" once done); a `ProgressView` while
    running; disabled during.
  - The summary (markdown, `Text(.init(...))`) and the transcript (markdown), or an empty-state
    ("Not transcribed yet — tap Transcribe & Summarize.").
  - A Delete button (calls `meetingStore.delete(id:)`).
- Porcelain throughout; rows are real `Button`s (keyboard/VoiceOver), matching D4a.
- `MeetingsSettingsView.swift`: check for remaining references; if the hub `.meetings` case was
  its only use (expected post-D2b), delete it (its toggle is inlined here). Otherwise leave it.

### 6. Tests (`omwhisper-nativeTests/`)

- `MeetingStoreTests` — real GRDB round-trips: insert → get → fetchPage ordering (newest first,
  `id` tiebreaker like `MemoryStore`), `setTranscriptAndSummary`, search (FTS over transcript/
  summary), delete (row gone; and a seeded temp directory is removed), deleteAll.
- `MeetingTranscriberTests` — `labeledTranscript`: both tracks, one empty, both empty.
- `MeetingSummarizerTests` — `chunk`: packs under limit, splits at limit, an oversized single
  block gets its own chunk (same cases as `ChroniclerTests`).
- Full suite stays green (251 → ~262).

## Live verification (owed)

Automated tests cover the store + pure helpers; the two effectful paths are verified live:
1. **File transcription** — record a short real meeting (or feed a known `.caf`), tap Transcribe,
   confirm a plausible speaker-labeled transcript appears (this proves the file→buffer→AppleEngine
   path — the main risk).
2. **Summary** — confirm the summary + action items read sensibly on `SystemLLM`, and that a
   meeting with Foundation Models off still stores a transcript (summary omitted, nudge shown).
3. End-to-end: record a real Meet/Zoom call → it appears in the list → transcribe+summarize →
   browse it (the S3 exit criterion).

## Out of scope (explicit)

- **Auto-transcription on stop** (background queue + persisted processing state) — the chosen
  manual button ships first; auto is a follow-up.
- **Turn-by-turn speaker interleaving** — needs per-segment timestamps the engine doesn't expose.
- **Cloud/Ollama/Parakeet for meetings** — on-device only, by decision.
- **Audio playback** in the detail pane, per-meeting rename/notes, export — not needed for the
  milestone; add later if wanted.
- **MCP exposure of meetings** — S5.2's MCP server covers memory/history; adding meetings there
  is a separate, optional follow-up.
