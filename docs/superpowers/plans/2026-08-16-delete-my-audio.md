# Delete My Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user remove their own microphone from a meeting that is already recorded — the audio file, the "You" turns in the transcript, and the summary written from them — for the case where they forgot to turn the mic off.

**Architecture:** A pure block-filter drops `**You:**` blocks from the stored transcript markdown; a store method rewrites transcript + summary + `micCaptured` in one write; `AppState` sequences delete-audio → strip-transcript → clear-summary → regenerate, in that order, so an interruption always leaves the recording more private rather than less.

**Tech Stack:** Swift 6 (MainActor-by-default), GRDB (+ FTS5 synchronize triggers), SwiftUI, Swift Testing.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-16-delete-my-audio-design.md`. Read it before starting.
- **The order is the design.** Delete `me.caf` → strip the transcript → clear the summary → regenerate → set `micCaptured = false`. Each step is persisted before the next begins. Never reorder so that a failure preserves the leak.
- **Only a label line may be matched.** A body line containing the word "You" — `You mentioned the deadline`, said by Speaker 3 — must survive untouched. A `contains("You")` would silently delete other people's sentences while every store-level assertion still passed.
- **Clear the summary BEFORE attempting regeneration.** A backend that is unavailable, times out, or errors must leave no summary rather than the old one.
- Do not touch the title. `nameMeetingIfNeeded` only names from a summary when nothing better is known, and wiping a title the user typed costs more than it protects.
- Do not delete `them.caf`, do not build an arbitrary transcript editor, do not bulk-apply. All explicitly out of scope.
- New `AppState` settings backed by `UserDefaults` need `access(keyPath:)`/`withMutation(keyPath:)` — not needed here, but the rule stands if one is added.
- Any test touching a real `meetings.db` runs against a **copy**, never production. Kill OmWhisper-Dev before copying: a live SQLite file has inconsistent WAL state.
- Do not pipe the build — a pipeline returns the last command's status and hides failures. Redirect to a file.
- Build/test: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test`

---

## File Structure

| File | Responsibility |
|---|---|
| `omwhisper-native/Meetings/MeetingDiarization.swift` | `removingYouTurns(_:)` — the pure block filter, next to `applySpeakerNames` which does the same kind of label-anchored work |
| `omwhisper-native/Meetings/MeetingStore.swift` | `removeMicTrack(id:transcript:)` — one write for transcript + summary + micCaptured |
| `omwhisper-native/AppState.swift` | `deleteMeetingMicAudio(id:)` — sequences the four steps |
| `omwhisper-native/UI/HubMeetingsSectionView.swift` | The confirmed action, and the reworded header line |
| `omwhisper-nativeTests/MeetingDiarizationTests.swift` | Filter tests, including the body-mentions-You case |
| `omwhisper-nativeTests/MeetingStoreTests.swift` | The three fields change together |

---

### Task 1: The pure block filter

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingDiarization.swift`
- Test: `omwhisper-nativeTests/MeetingDiarizationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MeetingDiarization.removingYouTurns(_ markdown: String) -> String`

**Format being filtered.** Both stored transcript shapes are blank-line-separated blocks whose first line is a label:

- Diarized (`renderInterleaved`): `**Speaker 1:** [0:03]\ntext`
- Legacy (`labeledTranscript`): `**You:**\ntext`

A label is recognised exactly as `AppMarkdown.parseLabel` does — `**`, then the speaker, then `:**` — so the filter and the renderer cannot disagree about what a label is.

- [ ] **Step 1: Write the failing tests**

Add to `omwhisper-nativeTests/MeetingDiarizationTests.swift`:

```swift
    @Test("removingYouTurns drops You blocks from a diarized transcript")
    func removesYouFromDiarized() {
        let input = """
        **You:** [0:00]
        Let me put myself on mute.

        **Speaker 1:** [0:04]
        We shipped the release on Tuesday.

        **You:** [0:09]
        Did you see the game last night?

        **Speaker 2:** [0:12]
        The rollout looked clean.
        """
        let out = MeetingDiarization.removingYouTurns(input)
        #expect(out == """
        **Speaker 1:** [0:04]
        We shipped the release on Tuesday.

        **Speaker 2:** [0:12]
        The rollout looked clean.
        """)
    }

    @Test("removingYouTurns handles the legacy You/Others transcript")
    func removesYouFromLegacy() {
        let input = "**You:**\nmy side\n\n**Others:**\ntheir side"
        #expect(MeetingDiarization.removingYouTurns(input) == "**Others:**\ntheir side")
    }

    @Test("a body line that mentions You is never removed")
    func bodyMentionsAreSafe() {
        // The failure this exists for: a contains("You") filter would delete
        // Speaker 1 entirely — someone else's sentence, silently — and every
        // store-level assertion would still pass.
        let input = """
        **Speaker 1:** [0:02]
        You mentioned the deadline, and **You:** was in my notes too.

        **You:** [0:08]
        that was my aside
        """
        let out = MeetingDiarization.removingYouTurns(input)
        #expect(out.contains("You mentioned the deadline"))
        #expect(out.contains("**Speaker 1:**"))
        #expect(!out.contains("that was my aside"))
    }

    @Test("a transcript with no You turns is returned unchanged")
    func noYouTurnsIsUnchanged() {
        let input = "**Speaker 1:** [0:00]\nhello\n\n**Speaker 2:** [0:03]\nhi"
        #expect(MeetingDiarization.removingYouTurns(input) == input)
    }

    @Test("a transcript of only You turns becomes empty")
    func onlyYouTurnsBecomesEmpty() {
        #expect(MeetingDiarization.removingYouTurns("**You:** [0:00]\nall mine").isEmpty)
    }

    @Test("renamed speakers are not mistaken for You")
    func renamedSpeakersSurvive() {
        // applySpeakerNames rewrites labels at read time, but the STORED
        // transcript keeps generic labels. A meeting where someone is actually
        // named "Young" must not lose their turns to a prefix match.
        let input = "**Young:** [0:00]\nkeep me\n\n**You:** [0:04]\ndrop me"
        let out = MeetingDiarization.removingYouTurns(input)
        #expect(out == "**Young:** [0:00]\nkeep me")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t1.log 2>&1
echo "exit: $?"; grep -E "error:" /tmp/dma-t1.log | sed 's/.*error:/error:/' | sort -u | head
```
Expected: `error: type 'MeetingDiarization' has no member 'removingYouTurns'`

- [ ] **Step 3: Implement the filter**

Add to `MeetingDiarization.swift`, directly below `applySpeakerNames`:

```swift
    /// Drop every turn spoken by the user from a stored transcript.
    ///
    /// Block-filtering rather than `AppMarkdown.turns` → `renderInterleaved`: a
    /// round trip through the parser silently loses anything the parser does not
    /// model, where filtering preserves each surviving block verbatim.
    ///
    /// ONLY a label line is ever matched. A body line reading "You mentioned the
    /// deadline" belongs to whoever was speaking, and a `contains("You")` would
    /// delete their turn while every store-level assertion still passed.
    static func removingYouTurns(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n\n")
            .filter { block in
                // The label is the block's FIRST line, matched the way
                // AppMarkdown.parseLabel matches it, so the filter and the
                // renderer cannot disagree about what a label is.
                guard let first = block.split(separator: "\n", maxSplits: 1,
                                              omittingEmptySubsequences: false).first
                else { return true }
                return first.trimmingCharacters(in: .whitespaces).hasPrefix("**You:**") == false
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 4: Run to verify they pass**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t1.log 2>&1
echo "exit: $?"; grep -E "Test run with|Expectation failed" /tmp/dma-t1.log
```
Expected: PASS.

- [ ] **Step 5: Prove the body-mention test can fail**

Temporarily replace the filter's `return` line with the naive version:

```swift
                return block.contains("**You:**") == false
```

Re-run. Expected: `bodyMentionsAreSafe` FAILS (Speaker 1's block is deleted because the phrase appears in its body). Restore the correct line and confirm green. A guard against a mistake nobody can make is not a guard.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingDiarization.swift omwhisper-nativeTests/MeetingDiarizationTests.swift
git commit -m "✨ feat(meetings): pure filter that drops You turns from a transcript"
```

---

### Task 2: One store write for the three fields

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift`
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `Meeting.micCaptured: Bool?` (already exists).
- Produces: `MeetingStore.removeMicTrack(id: Int64, transcript: String?) throws`

**Why one method rather than reusing the existing ones:** `setTranscriptAndSummary` does not touch `micCaptured`, and `setSummary` does not touch the transcript. Doing this as two calls would leave a window where the transcript is stripped but the row still claims the mic was captured, and a crash between them would persist that. One write, one transaction.

- [ ] **Step 1: Write the failing test**

Add to `omwhisper-nativeTests/MeetingStoreTests.swift`:

```swift
    @Test("removeMicTrack rewrites transcript, clears the summary, and marks the mic gone")
    func removeMicTrackClearsEverything() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Teams")
        try store.setTranscriptAndSummary(
            id: id,
            transcript: "**You:** [0:00]\nprivate aside\n\n**Speaker 1:** [0:04]\nthe real meeting",
            summary: "## Summary\n\nThey discussed a private aside.",
            summaryBackend: "Ollama (qwen3.5:latest)")

        try store.removeMicTrack(id: id, transcript: "**Speaker 1:** [0:04]\nthe real meeting")

        let after = try #require(try store.get(id: id))
        // Asserted together on purpose: rewriting the transcript while leaving a
        // summary quoting the removed conversation would pass a check that only
        // looked at the transcript.
        #expect(after.transcript == "**Speaker 1:** [0:04]\nthe real meeting")
        #expect(after.summary == nil)
        #expect(after.summaryBackend == nil)
        #expect(after.micCaptured == false)
    }

    @Test("a phrase from the removed track stops matching a search")
    func removedTrackLeavesTheSearchIndex() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Teams")
        try store.setTranscriptAndSummary(
            id: id,
            transcript: "**You:** [0:00]\npomegranate marmalade\n\n**Speaker 1:** [0:04]\nquarterly numbers",
            summary: nil)
        #expect(try store.search("pomegranate").count == 1, "precondition: FTS indexed the transcript")

        try store.removeMicTrack(id: id, transcript: "**Speaker 1:** [0:04]\nquarterly numbers")

        // The check a user actually performs, and the one that fails if the
        // write bypasses GRDB's synchronize triggers.
        #expect(try store.search("pomegranate").isEmpty)
        #expect(try store.search("quarterly").count == 1, "the rest of the meeting must stay findable")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t2.log 2>&1
echo "exit: $?"; grep -E "error:" /tmp/dma-t2.log | sed 's/.*error:/error:/' | sort -u | head
```
Expected: `error: value of type 'MeetingStore' has no member 'removeMicTrack'`

If the compiler instead rejects `store.search(...)`, check its real signature with
`grep -n "func search" omwhisper-native/Meetings/MeetingStore.swift` and adjust the
two call sites — the assertion is what matters, not the argument label.

- [ ] **Step 3: Implement it**

Add to `MeetingStore.swift`, below `setSummary`:

```swift
    /// Remove the user's own microphone from a recorded meeting: the stripped
    /// transcript, no summary, and micCaptured false — in ONE write.
    ///
    /// Not two existing calls. `setTranscriptAndSummary` does not touch
    /// micCaptured and `setSummary` does not touch the transcript, so composing
    /// them would open a window where the transcript is stripped while the row
    /// still claims the mic was captured, and a crash between them would persist
    /// exactly that.
    ///
    /// The summary is cleared rather than kept: it was written from the
    /// unstripped transcript and may quote what is being removed. Regenerating
    /// it is the caller's job, deliberately afterwards, so a backend failure
    /// leaves no summary rather than the old one.
    func removeMicTrack(id: Int64, transcript: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.transcript = transcript
            m.summary = nil
            m.summaryBackend = nil
            m.micCaptured = false
            try m.update(db)
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t2.log 2>&1
echo "exit: $?"; grep -E "Test run with|Expectation failed" /tmp/dma-t2.log
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): removeMicTrack writes transcript, summary and provenance together"
```

---

### Task 3: Sequencing the four steps

**Files:**
- Modify: `omwhisper-native/AppState.swift`

**Interfaces:**
- Consumes: `MeetingDiarization.removingYouTurns(_:)` (Task 1), `MeetingStore.removeMicTrack(id:transcript:)` (Task 2), and the existing private `generateMeetingSummary(transcript:template:) async -> (summary: String, backend: String)?` and `MeetingSummarizer.template(id:custom:)`.
- Produces: `AppState.deleteMeetingMicAudio(id: Int64) async throws -> Meeting`

No unit test: constructing `AppState` opens the real history and memory stores, which is why no test in this suite does it. The pieces it composes are tested in Tasks 1 and 2; the sequencing is verified live in Task 4.

- [ ] **Step 1: Add the method**

Add to `AppState.swift`, directly after `regenerateSummary(id:templateID:)`:

```swift
    /// Remove the user's own microphone from a meeting that is already recorded.
    ///
    /// The ORDER is the feature, not an implementation detail. Deleting the
    /// audio alone fixes nothing — the private words are already in the
    /// transcript, which is the searchable, exportable, summarised copy. Each
    /// step is persisted before the next begins, so an interruption anywhere
    /// leaves the recording MORE private, never less.
    @discardableResult
    func deleteMeetingMicAudio(id: Int64) async throws -> Meeting {
        guard let store = meetingStore, let meeting = try store.get(id: id) else {
            throw MeetingStoreError.notFound
        }

        // 1. The audio. try? — a directory the user already cleaned out by hand
        //    must not stop the transcript being stripped.
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: meeting.directory).appendingPathComponent("me.caf"))

        // 2. + 3. The transcript, with no summary. One write, so there is no
        //    state where the transcript is clean but the row still claims the
        //    mic was captured.
        let stripped = meeting.transcript.map(MeetingDiarization.removingYouTurns)
        try store.removeMicTrack(id: id, transcript: (stripped?.isEmpty ?? true) ? nil : stripped)

        // 4. Regenerate, best-effort and deliberately LAST. The summary is
        //    already gone by now, so a backend that is unavailable or times out
        //    leaves this meeting with no summary — never the old one, which
        //    quoted what was just removed. The user can press Regenerate
        //    summary whenever they like.
        if let transcript = stripped, !transcript.isEmpty {
            let resolved = MeetingDiarization.applySpeakerNames(
                transcript, names: meeting.speakerNames ?? [:])
            let template = MeetingSummarizer.template(
                id: meetingTemplateID, custom: customMeetingTemplates)
            if let written = await generateMeetingSummary(transcript: resolved, template: template) {
                try? store.setTranscriptAndSummary(id: id, transcript: transcript,
                                                   summary: written.summary,
                                                   summaryBackend: written.backend)
            }
        }
        return try store.get(id: id) ?? meeting
    }
```

- [ ] **Step 2: Verify it builds and the suite stays green**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t3.log 2>&1
echo "exit: $?"; grep -E "error:" /tmp/dma-t3.log | sed 's/.*error:/error:/' | sort -u | head
grep -E "Test run with" /tmp/dma-t3.log
```
Expected: build clean, suite green.

If `generateMeetingSummary` or `MeetingSummarizer.template` reports a signature
mismatch, read the real one at its definition in `AppState.swift` /
`MeetingSummarizer.swift` and match it — `regenerateSummary(id:templateID:)`
directly above calls both and is the reference.

- [ ] **Step 3: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(meetings): sequence deleting the user's own audio from a recording"
```

---

### Task 4: The confirmed action and the reworded header

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`

**Interfaces:**
- Consumes: `AppState.deleteMeetingMicAudio(id:)` (Task 3).
- Produces: no new API.

No unit tests — SwiftUI wiring, verified live by this project's convention. Use `Color.Porcelain.*` tokens only.

- [ ] **Step 1: Add the confirmation state**

Beside the view's existing `@State private var editingSummary = false`:

```swift
    @State private var confirmingMicDelete = false
```

- [ ] **Step 2: Add the action button**

In the action row, between `Button("Edit details")` and `Button("Delete", role: .destructive)`:

```swift
                if meeting.micCaptured != false {
                    // Hidden once there is nothing left to delete, so the button
                    // never offers an action that would do nothing.
                    Button("Delete my audio…") { confirmingMicDelete = true }
                        .disabled(busy)
                }
```

- [ ] **Step 3: Add the confirmation dialog**

Attached to the same container the existing `.sheet` modifiers hang off:

```swift
        .confirmationDialog("Delete your microphone from this meeting?",
                            isPresented: $confirmingMicDelete, titleVisibility: .visible) {
            Button("Delete my audio", role: .destructive) { deleteMicAudio() }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Says what is lost as well as what is removed. This is confirmed
            // where the live Discard button is not: there is no time pressure
            // here, and it cannot be undone.
            Text("Removes your audio track, every turn you spoke, and the summary written from them. The rest of the meeting is kept. This can't be undone.")
        }
```

- [ ] **Step 4: Add the action handler**

Beside the view's existing `saveSummary()` / `delete()` helpers:

```swift
    private func deleteMicAudio() {
        guard let id = meeting.id else { return }
        busy = true
        Task {
            defer { busy = false }
            do { onChanged(try await appState.deleteMeetingMicAudio(id: id)) }
            catch { errorMessage = "Couldn't remove your audio from this meeting." }
        }
    }
```

If the surrounding view refreshes differently — check how `delete()` and
`saveSummary()` propagate their result — match that mechanism rather than
introducing `onChanged`. The requirement is that the detail pane re-reads the
row after the action; the means is whatever this file already does.

- [ ] **Step 5: Reword the header line**

In `metaLine`, change:

```swift
        if meeting.micCaptured == false { parts.append("Your microphone wasn't recorded") }
```

to:

```swift
        // True whether the mic was never recorded or was recorded and removed.
        // "wasn't recorded" would be a lie about history in the second case, and
        // a third state for one line of copy is not worth carrying.
        if meeting.micCaptured == false { parts.append("Your microphone isn't in this recording") }
```

- [ ] **Step 6: Build, test, relaunch**

Run:
```bash
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test > /tmp/dma-t4.log 2>&1
echo "exit: $?"; grep -E "error:" /tmp/dma-t4.log | sed 's/.*error:/error:/' | sort -u | head
grep -E "Test run with" /tmp/dma-t4.log
xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj -configuration Debug build > /tmp/dma-build.log 2>&1
APP="$HOME/Library/Developer/Xcode/DerivedData/omwhisper-native-fxpcbydguyylgrazhqwstjzordaj/Build/Products/Debug/OmWhisper-Dev.app"
pkill -x OmWhisper-Dev; sleep 1; open "$APP"
```

- [ ] **Step 7: Live-verify, on a meeting that has a "You" turn**

Pick a real recorded meeting whose transcript contains at least one `You` turn,
and note a distinctive phrase from it first — that phrase is the instrument.

1. **Before:** search that phrase in the Meetings search field. It finds the meeting.
2. Press **Delete my audio…**, confirm.
3. **After:**
   - `ls "$HOME/Library/Application Support/com.omwhisper.mac.dev/Meetings/<that meeting>/"` → `me.caf` **absent**, `them.caf` present.
   - The transcript shows no `You` turns, and the other speakers' turns are unchanged.
   - Searching the phrase from step 1 finds **nothing**. This is the check that fails if the rewrite bypassed the FTS triggers.
   - The header reads "Your microphone isn't in this recording".
   - A summary either regenerated or is absent — never the old one mentioning the removed exchange.
4. **Control:** open a different meeting that still has its mic track and confirm its `You` turns and `me.caf` are untouched. Without this, "the transcript has no You turns" is equally explained by having broken transcript rendering for every meeting.

- [ ] **Step 8: Commit**

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): Delete my audio on a recorded meeting"
```

---

## Self-Review

**Spec coverage.** Confirmed action → Task 4. Delete `me.caf` → Task 3 step 1. Strip `**You:**` blocks → Task 1, called in Task 3. Clear summary before regenerating → Task 2 (`removeMicTrack` nils it) and Task 3 (regeneration comes after). `micCaptured = false` → Task 2. Copy change → Task 4 step 5. Title untouched → no task writes it; `removeMicTrack` names the fields it sets. Re-transcribe safe afterwards → no change needed, `me.caf` is gone and `transcribeFile` already returns "" for a missing file. Every test named in the spec's Testing section appears in Task 1 or Task 2, including the FTS check and the body-mentions-You case. Out-of-scope items appear nowhere.

**Two gaps found and closed while reviewing:**
1. The spec's tests did not cover a **speaker genuinely named something starting with "You"** — "Young". `hasPrefix("**You:**")` is safe because the `:**` is part of the match, but nothing pinned that, so `renamedSpeakersSurvive` was added to Task 1.
2. Task 4 originally always showed the button. On a meeting where the mic was never recorded it would run the whole sequence to delete nothing and clear a valid summary. It is now hidden when `micCaptured == false`.

**Type consistency.** `removingYouTurns(_:) -> String` (non-optional) is called through `Optional.map` in Task 3, giving `String?`, which matches `removeMicTrack(id:transcript:)`'s `String?`. `micCaptured` is `Bool?` on `Meeting` throughout. `deleteMeetingMicAudio(id:)` returns `Meeting`, matching `regenerateSummary`'s shape so the view's existing refresh path fits.
