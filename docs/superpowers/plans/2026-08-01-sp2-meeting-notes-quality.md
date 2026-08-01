# SP2 — Meeting Notes Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meeting summaries get big-model quality on long calls (Ollama as a local backend with 12k-char chunks), selectable structure (5 built-in + custom templates), and in-place editing — per `docs/superpowers/specs/2026-08-01-meetings-competitive-parity-design.md` §3.

**Architecture:** `MeetingSummarizer.generate` gains `template` and `chunkLimit` parameters (defaults preserve today's behavior). `AppState` picks the summary backend for meetings: Ollama when it's the user's polish backend and configured, else SystemLLM — Cloud never (recorded calls don't egress even as text); an Ollama failure retries once via SystemLLM. Templates are `PolishStyle` values: 5 fixed-UUID built-ins in `MeetingSummarizer` plus user customs stored like `customPolishStyles`; only the reduce-stage prompt varies. Summary editing writes through a new `MeetingStore.setSummary`.

**Tech Stack:** Swift 6 (MainActor-by-default), existing `PolishBackend`/`Ollama`/`SystemLLM`, GRDB, Swift Testing.

## Global Constraints

- Meetings NEVER egress: `CloudLLM` must never appear in the meeting-summary path, regardless of the user's polish backend.
- New settings use `access(keyPath:)`/`withMutation(keyPath:)` (the `@Observable`-over-UserDefaults rule).
- Template prompts must instruct section bodies on the line AFTER each `## ` heading — never the `## Summary — body` single-line format (the blank-summary-card bug's cause; the parser now tolerates it, prompts must not teach it).
- Existing `MeetingSummarizer.generate(transcript:polish:)` call sites and tests must keep compiling — new parameters take defaults.
- Full-suite command: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -4`. Single suite: `xcodebuild test ... -only-testing:omwhisper-nativeTests/<SuiteName>`.
- Commit style: emoji conventional commits. Isolated workspace per session convention (worktree via the native tool).

---

### Task 1: Templates + parameterized `MeetingSummarizer.generate`

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingSummarizer.swift`
- Test: `omwhisper-nativeTests/MeetingSummarizerTests.swift`

**Interfaces:**
- Produces: `MeetingSummarizer.builtInTemplates: [PolishStyle]` (Standard/Standup/Client call/1:1/Interview; Standard keeps `meetingWriteStyle`'s existing UUID `…0002` so a stored default survives); `template(id: UUID?, custom: [PolishStyle]) -> PolishStyle` (nil/unknown → Standard); `ollamaChunkLimit = 12_000`; `generate(transcript:polish:template:chunkLimit:)` — `template` defaults to Standard, `chunkLimit` to `chunkCharLimit` (1,800).
- Consumes: `PolishStyle` (existing Codable struct with fixed-UUID pattern).

- [ ] **Step 1: Write the failing tests**

Append to `omwhisper-nativeTests/MeetingSummarizerTests.swift` (check the suite's existing imports; add a minimal recording fake — if `ChroniclerTests` already defines one, still define this locally with a distinct name, tests must read standalone):

```swift
    /// Records which style each polish() call received; returns canned text.
    private struct RecordingPolish: PolishBackend {
        let record: @Sendable (UUID) -> Void
        func polish(_ text: String, style: PolishStyle, targetLanguage: String?) async throws -> String {
            record(style.id)
            return "out"
        }
    }

    @Test func templateLookupFallsBackToStandard() {
        let custom = PolishStyle(id: UUID(), name: "Mine", prompt: "p", isBuiltIn: false)
        #expect(MeetingSummarizer.template(id: custom.id, custom: [custom]).id == custom.id)
        #expect(MeetingSummarizer.template(id: nil, custom: []).id == MeetingSummarizer.meetingWriteStyle.id)
        #expect(MeetingSummarizer.template(id: UUID(), custom: []).id == MeetingSummarizer.meetingWriteStyle.id)
    }

    @Test func builtInTemplatesAreFixedAndStandardIsFirst() {
        let ids = MeetingSummarizer.builtInTemplates.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(MeetingSummarizer.builtInTemplates.first?.id == MeetingSummarizer.meetingWriteStyle.id)
    }

    @Test func generateUsesTheGivenTemplateForTheReduceCall() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [UUID]())
        let fake = RecordingPolish { id in seen.withLock { $0.append(id) } }
        let standup = MeetingSummarizer.builtInTemplates[1]
        _ = try await MeetingSummarizer.generate(
            transcript: "**You:** [0:00]\nhello world", polish: fake, template: standup)
        let ids = seen.withLock { $0 }
        // map call(s) use the chunk style; the final reduce call uses the template.
        #expect(ids.first == MeetingSummarizer.chunkSummaryStyle.id)
        #expect(ids.last == standup.id)
    }

    @Test func chunkLimitParameterIsHonored() {
        // 12k-limit chunking packs a long transcript into far fewer groups.
        let words = Array(repeating: "word", count: 4_000).joined(separator: " ")
        let small = MeetingSummarizer.chunk(words, limit: MeetingSummarizer.chunkCharLimit).count
        let large = MeetingSummarizer.chunk(words, limit: MeetingSummarizer.ollamaChunkLimit).count
        #expect(large < small)
        #expect(large == 2)  // 4,000 words ≈ 20k chars → 2 groups at 12k
    }
```

Add `import os` to the test file if `OSAllocatedUnfairLock` is unresolved.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingSummarizerTests 2>&1 | tail -5`
Expected: COMPILE FAILURE — `builtInTemplates`/`template(id:custom:)`/`ollamaChunkLimit`/`template:` label undefined.

- [ ] **Step 3: Implement**

In `MeetingSummarizer.swift`:

1. Add below `chunkCharLimit`:

```swift
    /// Ollama takes ~10× bigger chunks than SystemLLM's 1,800-char envelope —
    /// an hour-long call goes from ~40 lossy chunks to ~6, which is the whole
    /// point of routing meeting summaries through it. Fits its 30s timeout.
    /// ponytail: tune only if live testing shows timeouts.
    static let ollamaChunkLimit = 12_000
```

2. Reword `meetingWriteStyle`'s format instruction so the body never lands on the heading line, keeping everything else:

```swift
    static let meetingWriteStyle = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000002")!,
        name: "Standard",
        prompt: """
            You are writing a private summary of a meeting from bullet-point notes. \
            "You" in the notes means the person who recorded the meeting; \
            "Speaker 1", "Speaker 2", … are the other participants. Write concise \
            markdown with a "## Summary" heading followed on the NEXT lines by 2-4 \
            sentences on what the meeting was about and any decisions, then a \
            "## Action items" heading followed by a bullet list of concrete \
            follow-ups (who owns each, if clear). Never put content on the same \
            line as a heading. Omit the Action items section entirely if there \
            were none. Rules: be specific, no filler, no speculation beyond the \
            notes. Never credit the recorder with a plan, opinion or commitment \
            that another speaker voiced — if a note doesn't say the recorder said \
            it, they didn't.
            """,
        isBuiltIn: true
    )
```

3. Add the template registry after `meetingWriteStyle`:

```swift
    // MARK: Templates — the reduce-stage prompt is the only thing that varies.
    // Fixed UUIDs (…0003-0006) so a stored default survives relaunches, same
    // pattern as every hidden style in this app. All share the attribution rule
    // and the bodies-below-headings format rule (the blank-card lesson).

    private static let attributionRules = """
        "You" in the notes means the person who recorded the meeting; other \
        names/labels are the other participants. Never credit the recorder with \
        something another speaker said. Never put content on the same line as a \
        "## " heading — headings alone, bodies on the following lines. Be \
        specific, no filler, no speculation beyond the notes. Omit any section \
        with nothing real to say.
        """

    static let standupTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000003")!,
        name: "Standup",
        prompt: """
            You are writing private standup notes from bullet-point meeting notes. \
            Write concise markdown with these headings: "## Updates" (one bullet \
            per person: what they did / are doing), "## Blockers" (who is blocked \
            and on what), "## Action items" (concrete follow-ups with owners). \
            \(attributionRules)
            """,
        isBuiltIn: true
    )

    static let clientCallTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000004")!,
        name: "Client call",
        prompt: """
            You are writing private notes on a client call from bullet-point \
            meeting notes. Write concise markdown with these headings: \
            "## Summary" (what the call was about), "## Client needs" (what the \
            client asked for, worried about, or objected to), "## Commitments" \
            (what was promised, by whom, by when), "## Next steps". \
            \(attributionRules)
            """,
        isBuiltIn: true
    )

    static let oneOnOneTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000005")!,
        name: "1:1",
        prompt: """
            You are writing private notes on a one-on-one conversation from \
            bullet-point meeting notes. Write concise markdown with these \
            headings: "## Topics" (what was discussed), "## Feedback" (given or \
            received, attributed correctly), "## Action items" (who follows up \
            on what). \(attributionRules)
            """,
        isBuiltIn: true
    )

    static let interviewTemplate = PolishStyle(
        id: UUID(uuidString: "7A3B2D40-0000-4A00-8000-000000000006")!,
        name: "Interview",
        prompt: """
            You are writing private interview notes from bullet-point meeting \
            notes. Write concise markdown with these headings: "## Candidate" \
            (role/background as discussed), "## Strengths" (with the evidence \
            mentioned), "## Concerns" (gaps or doubts raised), "## Next steps". \
            \(attributionRules)
            """,
        isBuiltIn: true
    )

    /// Standard first — it's the default and the UI lists them in this order.
    static let builtInTemplates: [PolishStyle] = [
        meetingWriteStyle, standupTemplate, clientCallTemplate, oneOnOneTemplate, interviewTemplate,
    ]

    /// Resolve a stored template choice; nil or unknown (e.g. a deleted custom
    /// template) falls back to Standard rather than failing the summary.
    static func template(id: UUID?, custom: [PolishStyle]) -> PolishStyle {
        guard let id else { return meetingWriteStyle }
        return builtInTemplates.first(where: { $0.id == id })
            ?? custom.first(where: { $0.id == id })
            ?? meetingWriteStyle
    }
```

4. Parameterize `generate` (defaults keep every existing call site/test compiling):

```swift
    /// Effectful: map each chunk → chunk-summary, reduce → markdown summary
    /// shaped by `template`. Returns "" for an empty transcript. Propagates the
    /// first polish() failure.
    static func generate(
        transcript: String,
        polish: PolishBackend,
        template: PolishStyle = meetingWriteStyle,
        chunkLimit: Int = chunkCharLimit
    ) async throws -> String {
        let chunks = chunk(transcript, limit: chunkLimit)
        guard !chunks.isEmpty else { return "" }

        var chunkSummaries: [String] = []
        for group in chunks {
            let summary = try await polish.polish(group, style: chunkSummaryStyle, targetLanguage: nil)
            chunkSummaries.append(summary)
        }

        let reduceInput = String(chunkSummaries.joined(separator: "\n").prefix(chunkLimit))
        let out = try await polish.polish(reduceInput, style: template, targetLanguage: nil)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

Note `reduceCharLimit` becomes unused by `generate` — delete the constant (its only consumer was this function; verify with a grep before deleting).

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingSummarizerTests 2>&1 | tail -5`
Expected: PASS. (If `RecordingPolish` fails to conform, read `PolishBackend`'s exact requirement in `Polish/PolishBackend.swift` and match it — do not change the protocol.)

- [ ] **Step 5: Full suite** (the `meetingWriteStyle` rename "Meeting Summary"→"Standard" and prompt rewording must not break anything)

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -4`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add omwhisper-native/Meetings/MeetingSummarizer.swift omwhisper-nativeTests/MeetingSummarizerTests.swift
git commit -m "✨ feat(meetings): 5 built-in summary templates + parameterized generate"
```

---

### Task 2: Backend routing — Ollama-or-System with retry-once fallback

**Files:**
- Modify: `omwhisper-native/AppState.swift` (`transcribeMeeting`, `regenerateSummary`, new settings + helper, `SettingsKeys`)

**Interfaces:**
- Produces: `AppState.meetingTemplateID: UUID?` (default nil = Standard), `AppState.customMeetingTemplates: [PolishStyle]`, `meetingSummaryBackends() -> [(polish: PolishBackend, chunkLimit: Int)]` (ordered candidates), `regenerateSummary(id:templateID:)` (templateID nil = the stored default).
- Consumes: Task 1's `template(id:custom:)`, `ollamaChunkLimit`, `generate(transcript:polish:template:chunkLimit:)`; existing `Ollama(baseURL:model:)`, `SystemLLM.isAvailable()`, `polishBackend`/`ollamaBaseURL`/`ollamaModel` settings.

No new pure logic beyond settings plumbing (candidate ordering is two `if`s reading live state); per project convention the routing is live-verified (Task 5). The settings follow the exact `customPolishStyles`/`autoDeleteAfterDays` patterns.

- [ ] **Step 1: Add settings**

Next to `meetingsCalendarEnabled` in `AppState.swift`:

```swift
    /// Default summary template for meetings; nil = Standard. Stored as a UUID
    /// string; unknown IDs (deleted custom template) resolve to Standard at use.
    var meetingTemplateID: UUID? {
        get {
            access(keyPath: \.meetingTemplateID)
            guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.meetingTemplateID) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            withMutation(keyPath: \.meetingTemplateID) {
                UserDefaults.standard.set(newValue?.uuidString, forKey: SettingsKeys.meetingTemplateID)
            }
        }
    }

    /// User-authored meeting templates — same storage pattern as
    /// customPolishStyles, but a separate list: these never appear in the AI
    /// tab's dictation-style picker, and vice versa.
    var customMeetingTemplates: [PolishStyle] {
        get {
            access(keyPath: \.customMeetingTemplates)
            guard let data = UserDefaults.standard.data(forKey: SettingsKeys.customMeetingTemplates) else { return [] }
            return (try? JSONDecoder().decode([PolishStyle].self, from: data)) ?? []
        }
        set {
            withMutation(keyPath: \.customMeetingTemplates) {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: SettingsKeys.customMeetingTemplates)
            }
        }
    }
```

In `SettingsKeys`:

```swift
    static let meetingTemplateID = "meetingTemplateID"
    static let customMeetingTemplates = "customMeetingTemplates"
```

- [ ] **Step 2: Candidate helper + routing**

Add near `transcribeMeeting`:

```swift
    /// Summary backends for meetings, in try-order. Ollama first when it's the
    /// user's polish backend and configured (local, zero egress — "on-device"
    /// ≠ "SystemLLM-only"), SystemLLM as primary otherwise and as the retry
    /// when Ollama fails mid-summary. Cloud NEVER appears here: recorded calls
    /// don't egress even as text, regardless of the polish backend.
    private func meetingSummaryBackends() -> [(polish: PolishBackend, chunkLimit: Int)] {
        var candidates: [(PolishBackend, Int)] = []
        if polishBackend == .ollama, !ollamaModel.isEmpty {
            candidates.append((Ollama(baseURL: ollamaBaseURL, model: ollamaModel), MeetingSummarizer.ollamaChunkLimit))
        }
        if SystemLLM.isAvailable() {
            candidates.append((systemLLM, MeetingSummarizer.chunkCharLimit))
        }
        return candidates
    }

    /// First candidate that produces a summary; nil when all fail or none exist.
    private func generateMeetingSummary(transcript: String, template: PolishStyle) async -> String? {
        for candidate in meetingSummaryBackends() {
            if let summary = try? await MeetingSummarizer.generate(
                transcript: transcript, polish: candidate.polish,
                template: template, chunkLimit: candidate.chunkLimit
            ), !summary.isEmpty {
                return summary
            }
        }
        return nil
    }
```

In `transcribeMeeting(id:)`, replace the summary block:

```swift
        var summary: String?
        if SystemLLM.isAvailable() {
            summary = try? await MeetingSummarizer.generate(transcript: transcript, polish: systemLLM)
        } else if !didNudgeFoundationModelsUnavailable {
```

with:

```swift
        var summary: String?
        let template = MeetingSummarizer.template(id: meetingTemplateID, custom: customMeetingTemplates)
        if !meetingSummaryBackends().isEmpty {
            summary = await generateMeetingSummary(transcript: transcript, template: template)
        } else if !didNudgeFoundationModelsUnavailable {
```

(the `didNudge…` body and everything after stays as-is).

In `regenerateSummary`, change the signature to `func regenerateSummary(id: Int64, templateID: UUID? = nil) async throws -> Meeting` and replace its `SystemLLM.isAvailable()` guard + generate call:

```swift
        guard !meetingSummaryBackends().isEmpty else {
            errorMessage = "No on-device summarizer available — enable Apple Intelligence, or select Ollama in Settings > AI."
            return meeting
        }
        let resolved = MeetingDiarization.applySpeakerNames(
            transcript, names: meeting.speakerNames ?? [:])
        let template = MeetingSummarizer.template(
            id: templateID ?? meetingTemplateID, custom: customMeetingTemplates)
        guard let summary = await generateMeetingSummary(transcript: resolved, template: template) else {
            errorMessage = "Summary generation failed — check the log, or try again."
            return meeting
        }
        try store.setTranscriptAndSummary(id: id, transcript: transcript, summary: summary)
        return try store.get(id: id) ?? meeting
```

- [ ] **Step 3: Full build + suite**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -4`
Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add omwhisper-native/AppState.swift
git commit -m "✨ feat(meetings): summaries route through Ollama when selected — 12k chunks, System fallback"
```

---

### Task 3: Editable summary

**Files:**
- Modify: `omwhisper-native/Meetings/MeetingStore.swift` (one method)
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift` (summary card)
- Test: `omwhisper-nativeTests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `MeetingStore.setSummary(id: Int64, _ summary: String?) throws`.
- Consumes: existing `summaryCard`/`MarkdownSections` in the detail view.

- [ ] **Step 1: Failing test**

Append to `MeetingStoreTests.swift`:

```swift
    @Test func setSummaryUpdatesOnlyTheSummary() throws {
        let store = try makeStore()
        let id = try seed(store, app: "Zoom")
        try store.setTranscriptAndSummary(id: id, transcript: "**You:**\nhi", summary: "old")
        try store.setSummary(id: id, "## Summary\nedited by hand")
        let got = try store.get(id: id)
        #expect(got?.summary == "## Summary\nedited by hand")
        #expect(got?.transcript == "**You:**\nhi")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | tail -5`
Expected: COMPILE FAILURE — `setSummary` undefined.

- [ ] **Step 3: Implement the store method**

After `setSpeakerNames` in `MeetingStore.swift`:

```swift
    /// Summary only — the user editing their notes must never touch the transcript.
    func setSummary(id: Int64, _ summary: String?) throws {
        try dbQueue.write { db in
            guard var m = try Meeting.fetchOne(db, key: id) else { throw MeetingStoreError.notFound }
            m.summary = summary
            try m.update(db)
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme omwhisper-native -project omwhisper-native.xcodeproj -only-testing:omwhisper-nativeTests/MeetingStoreTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Editable summary card UI**

In `MeetingDetailView` (HubMeetingsSectionView.swift), add state:

```swift
    @State private var editingSummary = false
    @State private var summaryDraft = ""
```

Replace `summaryCard(_:)`:

```swift
    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if editingSummary {
                TextEditor(text: $summaryDraft)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                HStack(spacing: 8) {
                    Button("Cancel") { editingSummary = false }
                    Button("Save") { saveSummary() }.keyboardShortcut(.defaultAction)
                }
            } else {
                MarkdownSections(markdown: summary, fallbackTitle: "Summary")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Edit") {
                    summaryDraft = summary
                    editingSummary = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Porcelain.mint)
            }
        }
        .padding(18)
        .omCard()
    }

    private func saveSummary() {
        guard let id = meeting.id, let store = appState.meetingStore else { return }
        let trimmed = summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.setSummary(id: id, trimmed.isEmpty ? nil : trimmed)
        editingSummary = false
        Task { await onChanged() }
    }
```

(Editing raw markdown in monospace is deliberate — the stored format IS markdown and FTS indexes it; a rich editor is YAGNI. Regenerate overwrites edits, same as Meetily, no merge logic — per spec.)

- [ ] **Step 6: Full build + suite, commit**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -4` → TEST SUCCEEDED.

```bash
git add omwhisper-native/Meetings/MeetingStore.swift omwhisper-native/UI/HubMeetingsSectionView.swift omwhisper-nativeTests/MeetingStoreTests.swift
git commit -m "✨ feat(meetings): editable summary — raw markdown, summary-only write"
```

---

### Task 4: Template UI — default picker, custom CRUD, per-run menu

**Files:**
- Modify: `omwhisper-native/UI/HubMeetingsSectionView.swift`

**Interfaces:**
- Consumes: `MeetingSummarizer.builtInTemplates`, `appState.meetingTemplateID`/`customMeetingTemplates`, `appState.regenerateSummary(id:templateID:)`.
- Produces: no new API. Pure SwiftUI — no unit tests per convention; suite green + live checklist.

- [ ] **Step 1: Per-run template menu on Regenerate**

In `MeetingDetailView.header`, replace the plain Regenerate button with a Menu (primary action = default template; menu items = explicit choice for this run):

```swift
                if meeting.transcript != nil {
                    Menu("Regenerate summary") {
                        ForEach(allTemplates) { template in
                            Button(template.name) { regenerate(templateID: template.id) }
                        }
                    } primaryAction: {
                        regenerate(templateID: nil)
                    }
                    .disabled(busy)
                    .fixedSize()
                }
```

Add to `MeetingDetailView`:

```swift
    private var allTemplates: [PolishStyle] {
        MeetingSummarizer.builtInTemplates + appState.customMeetingTemplates
    }
```

Change `regenerate()` to `regenerate(templateID: UUID?)` and pass it through:

```swift
    private func regenerate(templateID: UUID?) {
        guard let id = meeting.id else { return }
        working = true
        errorMessage = nil
        Task {
            do { _ = try await appState.regenerateSummary(id: id, templateID: templateID) }
            catch { errorMessage = error.localizedDescription }
            await onChanged()
            working = false
        }
    }
```

- [ ] **Step 2: Templates sheet (default picker + custom CRUD)**

In `HubMeetingsSectionView`, add `@State private var showTemplates = false`, and in `settingsBar` after the calendar toggle:

```swift
            Button("Templates…") { showTemplates = true }
                .buttonStyle(.plain)
                .foregroundStyle(Color.Porcelain.mint)
```

Attach to the outer `VStack` in `body` (next to the `.alert`):

```swift
        .sheet(isPresented: $showTemplates) {
            MeetingTemplatesSheet()
                .environment(appState)
        }
```

Add at file scope:

```swift
/// Default-template picker + custom template CRUD. Deliberately simple: a
/// custom template is a name + a reduce-stage prompt, same PolishStyle shape
/// and storage pattern as the AI tab's custom styles, but a separate list —
/// meeting templates never appear in the dictation-style picker.
private struct MeetingTemplatesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newPrompt = ""

    private var allTemplates: [PolishStyle] {
        MeetingSummarizer.builtInTemplates + appState.customMeetingTemplates
    }

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary templates")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Porcelain.ink)

            Picker("Default template", selection: Binding(
                get: { state.meetingTemplateID ?? MeetingSummarizer.meetingWriteStyle.id },
                set: { state.meetingTemplateID = $0 == MeetingSummarizer.meetingWriteStyle.id ? nil : $0 }
            )) {
                ForEach(allTemplates) { Text($0.name).tag($0.id) }
            }

            if !appState.customMeetingTemplates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(appState.customMeetingTemplates) { template in
                        HStack {
                            Text(template.name).foregroundStyle(Color.Porcelain.ink)
                            Spacer()
                            Button("Delete", role: .destructive) { remove(template) }
                                .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("New template name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                TextField("Prompt (how to structure the notes)", text: $newPrompt, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                Button("Add template") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color.Porcelain.bg)
    }

    private func add() {
        appState.customMeetingTemplates.append(PolishStyle(
            id: UUID(), name: newName.trimmingCharacters(in: .whitespaces),
            prompt: newPrompt, isBuiltIn: false))
        newName = ""
        newPrompt = ""
    }

    private func remove(_ template: PolishStyle) {
        appState.customMeetingTemplates.removeAll { $0.id == template.id }
        if appState.meetingTemplateID == template.id { appState.meetingTemplateID = nil }
    }
}
```

(If `PolishStyle`'s memberwise init differs — e.g. an extra parameter — read `Polish/PolishStyles.swift` and match it exactly; several call sites in this plan construct one.)

- [ ] **Step 3: Full build + suite, commit**

Run: `xcodebuild -scheme omwhisper-native -project omwhisper-native.xcodeproj build test 2>&1 | tail -4` → TEST SUCCEEDED.

```bash
git add omwhisper-native/UI/HubMeetingsSectionView.swift
git commit -m "✨ feat(meetings): template picker, custom templates, per-run regenerate menu"
```

---

### Task 5: Live verification checklist (user, dev build — OmWhisper-Dev)

1. **Template switching**: on the existing test meeting, use the Regenerate menu → "Standup", then → "Client call": the summary's section structure visibly changes per template. Default template changed in Templates… sheet → plain Regenerate uses it.
2. **Custom template**: add one ("Podcast notes": "## Key ideas / ## Quotes"), regenerate with it → structure follows the custom prompt; delete it → default picker falls back to Standard.
3. **Editable summary**: Edit → change a line → Save → card re-renders with the edit; pill stays SUMMARIZED; the edit survives app relaunch; FTS finds the edited text (search for a word you added).
4. **Ollama routing** (needs Ollama running + a model pulled + polish backend = Ollama): regenerate → summary generated via Ollama (check `log stream` shows no SystemLLM chunking storm; an hour-scale transcript produces a coherent summary). Stop Ollama → regenerate → falls back to SystemLLM (summary still appears).
5. **Regression**: polish backend = System or Disabled → summaries behave exactly as before this change (System used when available, nudge when not).
